import SwiftUI
import AppKit
import QuartzCore

// The new tab's picture (docs/PLAN.md 6, E), made of nothing but Core
// Animation layers: the Xool mark in the middle, a few fine streaks
// running out from behind it like a jump to light speed, and a very flat,
// slow wave of metal along the bottom. The animations run in the render
// server, not in the app: no timer, no frames drawn here.
//
// It runs only while a new tab is in front, its window is in sight and the
// app is active; otherwise the layers are paused. With Reduce Motion, or
// Settings › Appearance › "Moving background on a new tab" off, it stands
// still, a single frame of the same scene. Light and dark have their own greys.

struct NewTabScene: View {
    @ObservedObject private var prefs = Shared.prefs

    var body: some View {
        GeometryReader { page in
            // The field is centred and lifted 30 over the window; the page's
            // card is a little shorter than the window: the mark stands a
            // fixed way above the field's top.
            let centre = CGPoint(x: page.size.width / 2, y: page.size.height / 2 - 10 - 26 - 48 - 23)
            SceneRepresentable(centre: centre, moving: prefs.newTabMotion)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SceneRepresentable: NSViewRepresentable {
    let centre: CGPoint
    let moving: Bool

    func makeNSView(context: Context) -> SceneView { SceneView() }

    func updateNSView(_ view: SceneView, context: Context) {
        view.setScene(centre: centre, moving: moving)
    }
}

/// The scene's layers. Top-left origin, so SwiftUI's numbers go in as they are.
final class SceneView: NSView {
    static let markSize = CGSize(width: 56, height: 46)
    private let streakCount = 16

    private let root = CALayer()
    private let arms = CALayer()
    private var streaks: [Streak] = []
    private let wave = CAGradientLayer()
    private let waveMask = CAShapeLayer()
    private let glint = CAGradientLayer()
    private let mark = CAGradientLayer()
    private let markMask = CAShapeLayer()

    private struct Streak {
        let arm: CALayer
        let line: CAGradientLayer
        let angle: CGFloat
        let duration: Double
        let phase: Double
        let progress: Double
    }

    private var centre = CGPoint(x: 100, y: 100)
    private var wantsMotion = true
    private var running = false
    private var built = false
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = root
        root.masksToBounds = true
        root.addSublayer(wave)
        root.addSublayer(arms)
        root.addSublayer(mark)
        glint.type = .radial
        wave.addSublayer(glint)
        wave.mask = waveMask
        mark.mask = markMask
        markMask.path = Self.markPath()
        markMask.fillColor = NSColor.black.cgColor
        for index in 0..<streakCount { addStreak(index) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func setScene(centre: CGPoint, moving: Bool) {
        let changed = centre != self.centre || moving != wantsMotion
        self.centre = centre
        wantsMotion = moving
        if changed || !built { rebuild() }
    }

    // MARK: look

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// A colour of the design tokens, resolved for this appearance.
    private func resolved(_ color: NSColor) -> NSColor {
        var out = color
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    /// Streak ink: cool white with blue in the dark, grey in the light; never past 35 %.
    private var streakColour: NSColor {
        isDark ? NSColor(srgbRed: 0.74, green: 0.84, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 1)
    }
    private let peak: Double = 0.32

    private func addStreak(_ index: Int) {
        // A fixed seed: the same scene on every launch, and in screenshots.
        var rng = SeededRandom(seed: UInt64(index * 7919 + 17))
        let arm = CALayer()
        let line = CAGradientLayer()
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        line.opacity = 0
        arm.addSublayer(line)
        arms.addSublayer(arm)
        // Spread round the circle with some jitter; streaks near straight
        // up would run into the logo's own line, so they thin out there.
        let base = (CGFloat(index) / CGFloat(streakCount)) * 2 * .pi
        let angle = base + CGFloat(rng.next(-0.18, 0.18))
        streaks.append(Streak(arm: arm, line: line, angle: angle, duration: rng.next(2.6, 4.6),
                              phase: rng.next(0, 1), progress: rng.next(0.18, 0.72)))
    }

    private func rebuild() {
        built = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let dark = isDark

        // The mark: metal, `text` down to `text-muted`.
        mark.bounds = CGRect(origin: .zero, size: Self.markSize)
        mark.position = centre
        mark.colors = [resolved(Theme.NS.text).cgColor, resolved(Theme.NS.textMuted).cgColor]
        mark.startPoint = CGPoint(x: 0.5, y: 0)
        mark.endPoint = CGPoint(x: 0.5, y: 1)
        markMask.frame = mark.bounds

        // Streaks, out from the mark's middle.
        arms.frame = bounds
        let reach = hypot(size.width, size.height) * 0.6
        let ink = streakColour
        for streak in streaks {
            streak.arm.bounds = .zero
            streak.arm.position = centre
            streak.arm.transform = CATransform3DMakeRotation(streak.angle, 0, 0, 1)
            streak.arm.removeAllAnimations()
            streak.line.removeAllAnimations()
            streak.line.bounds = CGRect(x: 0, y: 0, width: 150, height: 1.2)
            streak.line.colors = [ink.withAlphaComponent(0).cgColor, ink.cgColor]
            let near: CGFloat = 26
            if running {
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = near; move.toValue = reach
                move.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.9, 0.6)   // accelerates away
                let stretch = CABasicAnimation(keyPath: "transform.scale.x")
                stretch.fromValue = 0.15; stretch.toValue = 1.5
                stretch.timingFunction = move.timingFunction
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, peak, peak * 0.8, 0]
                fade.keyTimes = [0, 0.25, 0.7, 1]
                let group = CAAnimationGroup()
                group.animations = [move, stretch, fade]
                group.duration = streak.duration
                group.repeatCount = .infinity
                // Begun part of the way through, each its own way.
                group.beginTime = CACurrentMediaTime() - streak.phase * streak.duration
                group.isRemovedOnCompletion = false
                streak.line.add(group, forKey: "warp")
            } else {
                // The still frame: each streak caught part of the way out.
                let p = CGFloat(streak.progress)
                let eased = p * p
                streak.line.position = CGPoint(x: near + (reach - near) * eased, y: 0)
                streak.line.transform = CATransform3DMakeScale(0.15 + 1.35 * eased, 1, 1)
                streak.line.opacity = Swift.Float(peak * sin(Double.pi * Double(p)))
            }
        }

        // The wave: the bottom fifth at most, one surface, one glint.
        let height = min(size.height * 0.2, 150)
        wave.frame = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
        wave.colors = dark
            ? [NSColor(white: 1, alpha: 0.11).cgColor, NSColor(white: 0.75, alpha: 0.05).cgColor, NSColor(white: 0.5, alpha: 0.0).cgColor]
            : [NSColor(white: 0.25, alpha: 0.12).cgColor, NSColor(white: 0.45, alpha: 0.06).cgColor, NSColor(white: 0.6, alpha: 0.0).cgColor]
        wave.startPoint = CGPoint(x: 0.5, y: 0)
        wave.endPoint = CGPoint(x: 0.5, y: 1)
        waveMask.frame = wave.bounds
        waveMask.fillColor = NSColor.black.cgColor
        let low = Self.wavePath(in: wave.bounds, shift: 0)
        let high = Self.wavePath(in: wave.bounds, shift: 1)
        waveMask.path = low
        waveMask.removeAllAnimations()
        glint.removeAllAnimations()
        glint.frame = CGRect(x: size.width * 0.5 - 260, y: -height * 0.9, width: 520, height: height * 2.2)
        glint.colors = [NSColor(white: dark ? 1 : 0.15, alpha: dark ? 0.16 : 0.10).cgColor, NSColor(white: dark ? 1 : 0.15, alpha: 0).cgColor]
        glint.startPoint = CGPoint(x: 0.5, y: 0.5)
        glint.endPoint = CGPoint(x: 1, y: 1)
        if running {
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = low; morph.toValue = high
            morph.duration = 13
            morph.autoreverses = true
            morph.repeatCount = .infinity
            morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            waveMask.add(morph, forKey: "morph")
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = size.width * 0.28; drift.toValue = size.width * 0.72
            drift.duration = 31
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glint.add(drift, forKey: "drift")
        }
    }

    /// One flat swell across the width: four curves, so two of them can be
    /// morphed into each other. `shift` 0 and 1 are its two resting shapes.
    private static func wavePath(in rect: CGRect, shift: CGFloat) -> CGPath {
        let w = rect.width, h = rect.height
        let top = h * 0.30
        let amp = h * 0.16
        let p = CGMutablePath()
        let ys: [CGFloat] = shift == 0
            ? [top, top - amp, top + amp * 0.5, top - amp * 0.3, top]
            : [top - amp * 0.4, top + amp * 0.6, top - amp, top + amp * 0.3, top - amp * 0.2]
        p.move(to: CGPoint(x: 0, y: ys[0]))
        for i in 0..<4 {
            let x0 = w * CGFloat(i) / 4, x1 = w * CGFloat(i + 1) / 4
            let dx = (x1 - x0) * 0.45
            p.addCurve(to: CGPoint(x: x1, y: ys[i + 1]),
                       control1: CGPoint(x: x0 + dx, y: ys[i]),
                       control2: CGPoint(x: x1 - dx, y: ys[i + 1]))
        }
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }

    /// The Xool mark: an arch whose feet flare out, thick in the middle of
    /// each leg and fine at the foot, traced in a 56 × 46 box.
    static func markPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1, y: 45))
        p.addCurve(to: CGPoint(x: 28, y: 1), control1: CGPoint(x: 13, y: 40), control2: CGPoint(x: 17, y: 4))
        p.addCurve(to: CGPoint(x: 55, y: 45), control1: CGPoint(x: 39, y: 4), control2: CGPoint(x: 43, y: 40))
        p.addCurve(to: CGPoint(x: 42, y: 44), control1: CGPoint(x: 51, y: 45), control2: CGPoint(x: 46, y: 45))
        p.addCurve(to: CGPoint(x: 28, y: 14), control1: CGPoint(x: 38, y: 36), control2: CGPoint(x: 35, y: 14))
        p.addCurve(to: CGPoint(x: 14, y: 44), control1: CGPoint(x: 21, y: 14), control2: CGPoint(x: 18, y: 36))
        p.addCurve(to: CGPoint(x: 1, y: 45), control1: CGPoint(x: 10, y: 45), control2: CGPoint(x: 5, y: 45))
        p.closeSubpath()
        return p
    }

    // MARK: running and pausing

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification,
                         NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: name.rawValue.hasPrefix("NSApplication") ? nil : window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settle() }
                })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            })
        }
        settle()
    }

    /// Whether anyone can see it move: the window shown, the app in front,
    /// the setting on, and Reduce Motion off.
    private func settle() {
        let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let go = wantsMotion && !Motion.reduced && visible && NSApp.isActive && !NSApp.isHidden
        guard go != running else { return }
        running = go
        rebuild()
        if Store.testing || getenv("XOOL_PROFILE") != nil, getenv("XOOL_SCENE_LOG") != nil {
            FileHandle.standardError.write(Data("scene running=\(go)\n".utf8))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
    }
}

/// A small deterministic generator, so the still frame is always the same.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(_ low: Double, _ high: Double) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        return low + (high - low) * unit
    }
}
