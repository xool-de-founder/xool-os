import SwiftUI
import AppKit
import QuartzCore

// The Xool mark (docs/PLAN.md 8, A): a rounded square cut into four
// rounded triangles, bases on the outer edges, tips toward the middle. The
// gaps between them form an X. The triangles are matte silver; behind them,
// seen only in the X, lives a Liquid-Glass gradient with a slow wave, bright
// at the centre and fading to nothing at the four exits, with a light rim
// along the triangles' edges.
//
// Made of Core Animation layers only; the motion (≤ 0.3 Hz) runs in the render
// server. With Reduce Motion, or `animated: false`, it is one still frame.

enum XoolMarkShape {
    /// The unit the paths are built in; scaled to the size drawn.
    static let unit: CGFloat = 1000
    /// Half the gap's width, measured up the page (the X's arms are about
    /// 0.09 across), the roundness of every corner, and the plate's.
    private static let gap: CGFloat = 52
    private static let corner: CGFloat = 46
    private static let plateRadius: CGFloat = 270

    /// The plate: the rounded square all four triangles are cut from.
    static let plate: CGPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: unit, height: unit),
                                      cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

    /// The four triangles, top, right, bottom, left, in a 1000-point square.
    static let triangles: [CGPath] = {
        let c = unit / 2
        // Top: apex up the middle, its two edges the X's upper arms.
        let apex = CGPoint(x: c, y: c - gap)
        let reach: CGFloat = 700
        let top = CGMutablePath()
        top.move(to: apex)
        top.addLine(to: CGPoint(x: apex.x - reach, y: apex.y - reach))
        top.addLine(to: CGPoint(x: apex.x + reach, y: apex.y - reach))
        top.closeSubpath()
        return (0..<4).map { index in
            var turn = CGAffineTransform(translationX: c, y: c)
                .rotated(by: CGFloat(index) * .pi / 2)
                .translatedBy(x: -c, y: -c)
            let cut = top.copy(using: &turn) ?? top
            // The plate's own roundness cuts the base corners.
            let inside = cut.intersection(plate)
            return rounded(inside, by: corner)
        }
    }()

    /// All four as one shape.
    static let allTriangles: CGPath = {
        let all = CGMutablePath()
        for t in triangles { all.addPath(t) }
        return all
    }()

    /// Every convex corner rounded to `radius`: the shape eroded by it, then
    /// grown back with round joins.
    private static func rounded(_ path: CGPath, by radius: CGFloat) -> CGPath {
        let ring = path.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let core = path.subtracting(ring)
        let ringAgain = core.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return core.union(ringAgain)
    }

    /// `path` scaled to a square of `size` points.
    static func scaled(_ path: CGPath, to size: CGFloat) -> CGPath {
        var s = CGAffineTransform(scaleX: size / unit, y: size / unit)
        return path.copy(using: &s) ?? path
    }
}

/// The mark as a layer: triangles, glass, rim.
final class XoolMarkLayer: CALayer {
    private let glass = CALayer()
    private let glowBase = CAGradientLayer()
    private let wave = CAGradientLayer()
    private let glassMask = CAGradientLayer()
    private let plateMask = CAShapeLayer()
    private let metal = CAGradientLayer()
    private let metalMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let rimMask = CAShapeLayer()
    private(set) var dark = true
    private(set) var animated = false
    private var side: CGFloat = 0

    override init() {
        super.init()
        build()
    }
    override init(layer: Any) {
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        isOpaque = false
        glassMask.type = .radial
        glassMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        glassMask.endPoint = CGPoint(x: 1, y: 1)       // out to the corners: the X's exits
        glassMask.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.7).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        glassMask.locations = [0, 0.5, 1]
        glass.mask = glassMask
        glowBase.type = .radial
        glowBase.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowBase.endPoint = CGPoint(x: 1, y: 1)
        wave.type = .conic
        wave.startPoint = CGPoint(x: 0.5, y: 0.5)
        wave.endPoint = CGPoint(x: 0.5, y: 0)
        let clip = CALayer()
        clip.mask = plateMask
        plateMask.fillColor = NSColor.black.cgColor
        clip.addSublayer(glowBase)
        clip.addSublayer(wave)
        glass.addSublayer(clip)
        glassClip = clip
        addSublayer(glass)

        metal.startPoint = CGPoint(x: 0.3, y: 0)
        metal.endPoint = CGPoint(x: 0.7, y: 1)
        metalMask.fillColor = NSColor.black.cgColor
        metal.mask = metalMask
        addSublayer(metal)

        rim.fillColor = nil
        rim.lineJoin = .round
        rim.mask = rimMask
        rimMask.fillColor = NSColor.black.cgColor
        addSublayer(rim)
    }
    private var glassClip: CALayer?

    /// Lay the layers out for `side` points, in the light or dark palette.
    func configure(side: CGFloat, dark: Bool, animated: Bool) {
        guard side > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let changed = side != self.side || dark != self.dark || animated != self.animated
        self.side = side; self.dark = dark; self.animated = animated
        guard changed || metalMask.path == nil else { return }
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let frame = bounds
        for layer in [glass, metal, rim] { layer.frame = frame }
        glassClip?.frame = frame
        glassMask.frame = frame
        plateMask.frame = frame
        plateMask.path = XoolMarkShape.scaled(XoolMarkShape.plate, to: side)
        let triangles = XoolMarkShape.scaled(XoolMarkShape.allTriangles, to: side)
        metalMask.frame = frame
        metalMask.path = triangles
        rimMask.frame = frame
        rimMask.path = triangles

        // The wave spans more than the plate, so turning it never shows an edge.
        let big = side * 1.6
        glowBase.frame = frame
        wave.bounds = CGRect(x: 0, y: 0, width: big, height: big)
        wave.position = CGPoint(x: side / 2, y: side / 2)

        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        if dark {
            glowBase.colors = [c(0.74, 0.80, 1.0), c(0.46, 0.53, 0.86, 0.7), c(0.30, 0.36, 0.62, 0.0)]
            wave.colors = [c(1, 1, 1, 0), c(0.86, 0.90, 1.0, 0.55), c(0.55, 0.65, 1.0, 0.0), c(0.78, 0.84, 1.0, 0.45), c(1, 1, 1, 0)]
            metal.colors = [c(0.91, 0.92, 0.94), c(0.77, 0.78, 0.81), c(0.66, 0.67, 0.71)]
            rim.strokeColor = c(1, 1, 1, 0.34)
        } else {
            glowBase.colors = [c(0.36, 0.45, 0.88), c(0.52, 0.60, 0.92, 0.7), c(0.7, 0.75, 0.95, 0.0)]
            wave.colors = [c(1, 1, 1, 0), c(0.78, 0.84, 1.0, 0.7), c(0.5, 0.6, 1.0, 0.0), c(0.9, 0.93, 1.0, 0.55), c(1, 1, 1, 0)]
            metal.colors = [c(0.80, 0.81, 0.84), c(0.66, 0.67, 0.71), c(0.55, 0.56, 0.60)]
            rim.strokeColor = c(1, 1, 1, 0.5)
        }
        glowBase.locations = [0, 0.45, 1]
        wave.locations = [0, 0.25, 0.5, 0.75, 1]
        // A fine light line along the triangles' edges, kept inside them, and
        // a faint softening of the silver's edge.
        rim.lineWidth = max(0.5, side * 0.02)
        rim.path = triangles
        metal.shadowColor = c(1, 1, 1)
        metal.shadowOpacity = dark ? 0.0 : 0.0
        applyMotion()
    }

    private func applyMotion() {
        wave.removeAllAnimations()
        glowBase.removeAllAnimations()
        guard animated, !Motion.reduced else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = Double.pi * 2
        turn.duration = 18                      // 0.055 Hz
        turn.repeatCount = .infinity
        wave.add(turn, forKey: "turn")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.45; breathe.toValue = 1
        breathe.duration = 3.2                  // ≈ 0.16 Hz, there and back
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        wave.add(breathe, forKey: "breathe")
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 0.94; swell.toValue = 1.06
        swell.duration = 4.6
        swell.autoreverses = true
        swell.repeatCount = .infinity
        swell.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowBase.add(swell, forKey: "swell")
    }

    /// Run or stand still, e.g. while the window is out of sight.
    func setRunning(_ run: Bool) {
        if run, wave.animation(forKey: "turn") == nil { applyMotion() }
        if !run { wave.removeAllAnimations(); glowBase.removeAllAnimations() }
    }
}

/// The mark as a view of its own, square.
final class XoolMarkNSView: NSView {
    let markLayer = XoolMarkLayer()
    var animated = true { didSet { relayout() } }
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(markLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func layout() { super.layout(); relayout() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); relayout() }

    private func relayout() {
        let side = min(bounds.width, bounds.height)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        markLayer.configure(side: side, dark: dark, animated: animated && Self.shouldMove(window))
    }

    /// Still while the window is out of sight or the app in the background.
    static func shouldMove(_ window: NSWindow?) -> Bool {
        guard !Motion.reduced else { return false }
        guard let window else { return true }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            })
        }
        relayout()
    }
}

/// The mark in SwiftUI.
struct XoolMark: NSViewRepresentable {
    var size: CGFloat = 20
    var animated = true

    func makeNSView(context: Context) -> XoolMarkNSView {
        let view = XoolMarkNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.animated = animated
        return view
    }
    func updateNSView(_ view: XoolMarkNSView, context: Context) {
        view.animated = animated
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: XoolMarkNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

extension XoolMarkShape {
    /// The triangles alone as a template image (black on clear), for the
    /// menu bar, where macOS tints it.
    static func templateImage(side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(scaled(allTriangles, to: rect.width))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
