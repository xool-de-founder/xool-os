import SwiftUI
import AppKit

// The one source of values for Xool's look (docs/PLAN.md §3): Linear-clean,
// grey and quiet. Colour belongs to the agents alone.
//
// Dark is the default; light mirrors the steps. Palette (Design.swift), which
// Search's own views read, resolves to these tokens.
enum Theme {
    // MARK: colours

    enum NS {
        static let canvas = pair(light: 0xF7F7F8, dark: 0x0E0F11)
        static let surface = pair(light: 0xFFFFFF, dark: 0x16171A)
        static let raised = pair(light: 0xF1F1F3, dark: 0x1E1F23)
        static let line = pair(light: 0xE4E4E7, dark: 0x2A2B30)
        static let text = pair(light: 0x1B1C1F, dark: 0xE8E8EA)
        static let textMuted = pair(light: 0x6B6F78, dark: 0x8D919A)
        static let focus = pair(light: 0x4F5BD5, dark: 0x7C86E8)
        /// Between surface and raised: the row under the pointer.
        static let hover = pair(light: 0xF6F6F8, dark: 0x1A1B1F)
        /// Placeholders and idle glyphs: quiet, never the only carrier of meaning.
        static let faint = pair(light: 0xA1A4AC, dark: 0x565961)

        static func pair(light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return color(isDark ? dark : light)
            }
        }

        static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }

    static let canvas = Color(nsColor: NS.canvas)
    static let surface = Color(nsColor: NS.surface)
    static let raised = Color(nsColor: NS.raised)
    static let line = Color(nsColor: NS.line)
    static let text = Color(nsColor: NS.text)
    static let textMuted = Color(nsColor: NS.textMuted)
    static let focus = Color(nsColor: NS.focus)
    static let hover = Color(nsColor: NS.hover)
    static let faint = Color(nsColor: NS.faint)

    // MARK: type — 11 / 12 / 13 (base) / 15 / 20; weights 450 / 550 / 650

    enum Size {
        static let caption: CGFloat = 11
        static let small: CGFloat = 12
        static let base: CGFloat = 13
        static let large: CGFloat = 15
        static let title: CGFloat = 20
    }

    enum Weight {
        static let text = Font.Weight.regular      // 450
        static let label = Font.Weight.medium      // 550
        static let heading = Font.Weight.semibold // 650
    }

    /// Inter, once it is in the bundle; the system face until then.
    static let family: String? = {
        NSFont(name: "Inter", size: 13) != nil ? "Inter" : nil
    }()

    static func font(_ size: CGFloat, _ weight: Font.Weight = Weight.text) -> Font {
        if let family { return .custom(family, size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }

    static let body = font(Size.base)
    static let label = font(Size.base, Weight.label)
    static let small = font(Size.small)
    static let caption = font(Size.caption)
    static let heading = font(Size.large, Weight.heading)
    static let title = font(Size.title, Weight.heading)

    // MARK: shape and space

    enum Radius {
        static let chip: CGFloat = 4
        static let row: CGFloat = 6
        static let popover: CGFloat = 10
        static let avatar: CGFloat = 14
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// A hit target is at least this big (macOS pointer).
    static let target: CGFloat = 28

    // MARK: motion

    static let grow = Animation.easeOut(duration: 0.18)
    static let morph = Animation.easeInOut(duration: 0.22)
    static let hoverTime = Animation.easeOut(duration: 0.15)

    /// `animation`, or none with Reduce Motion (the Mac's or Search's own).
    static func motion(_ animation: Animation) -> Animation? {
        Motion.reduced ? nil : animation
    }
}

// MARK: - Agent colours: the only colour in the window

enum AgentColor: String, CaseIterable, Codable, Identifiable {
    case green, orange, blue, violet, teal, pink

    var id: String { rawValue }

    var hex: UInt32 {
        switch self {
        case .green: return 0x7BC47F
        case .orange: return 0xE07B45
        case .blue: return 0x5B7FE6
        case .violet: return 0x8B6CEB
        case .teal: return 0x6FB8A6
        case .pink: return 0xD9719A
        }
    }

    var name: String {
        switch self {
        case .green: return "Green"
        case .orange: return "Orange"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .teal: return "Teal"
        case .pink: return "Pink"
        }
    }

    /// The full colour: ring, avatar.
    var solid: Color { Color(nsColor: Theme.NS.color(hex)) }
    /// The 12 % wash behind a pill or a thread's header.
    var bg: Color { Color(nsColor: Theme.NS.color(hex, alpha: 0.12)) }
}

// MARK: - Focus ring and hover for every custom control

/// A focus ring that is always drawn when the control has the keyboard, and
/// Return / Space press it: SwiftUI's plain buttons draw nothing of their own.
struct XoolFocus: ViewModifier {
    let radius: CGFloat
    let action: (() -> Void)?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(true)
            .focused($focused)
            .focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                    .strokeBorder(Theme.focus, lineWidth: 2)
                    .padding(-2)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .onKeyPress(.return) { action?(); return action == nil ? .ignored : .handled }
            .onKeyPress(.space) { action?(); return action == nil ? .ignored : .handled }
    }
}

extension View {
    func xoolFocus(radius: CGFloat = Theme.Radius.row, action: (() -> Void)? = nil) -> some View {
        modifier(XoolFocus(radius: radius, action: action))
    }
}

/// A flat control: 28 pt hit target, hover wash, visible focus.
struct XoolButton<Label: View>: View {
    let radius: CGFloat
    let action: () -> Void
    let label: Label
    @XState private var hovering = false

    init(radius: CGFloat = Theme.Radius.row, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.radius = radius
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(minHeight: Theme.target)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(hovering ? Theme.raised : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.motion(Theme.hoverTime), value: hovering)
        .xoolFocus(radius: radius, action: action)
    }
}

/// An icon-only button with the accessibility label the plan demands.
struct XoolIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        XoolButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: Theme.target, height: Theme.target)
        }
        .accessibilityLabel(label)
        .help(label)
    }
}
