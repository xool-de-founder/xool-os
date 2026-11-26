import SwiftUI
import AppKit

/// The column's one foot row (docs/PLAN.md 6, G): `⚙ Settings` at the left;
/// at the right the keyboard (shortcuts) and light/dark. Quiet `text-muted`,
/// `text` on `raised` under the pointer; no accent colour, no profile picture.
struct SidebarFoot: View {
    static let height: CGFloat = 36
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var fetches: Fetches
    var live = true
    @ObservedObject private var ui = XoolUI.shared
    @Environment(\.colorScheme) private var scheme
    @XState private var settingsHover = false

    var body: some View {
        HStack(spacing: 2) {
            Button { browser.tuning = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).frame(width: 16)
                    Text("Settings").font(Theme.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(settingsHover ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(settingsHover ? Theme.raised : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { settingsHover = $0 }
            .xoolFocus(radius: Theme.Radius.row) { browser.tuning = true }
            .accessibilityLabel("Settings")
            .help("Settings")

            // Only while a download runs, and a moment after.
            FetchDoor(browser: browser, fetches: fetches, arrowEdge: prefs.sidePosition == .right ? .leading : .trailing, live: live)
            FootIcon(symbol: "keyboard", label: "Keyboard shortcuts", on: ui.showKeys) { ui.toggleKeys() }
            FootIcon(symbol: scheme == .dark ? "moon" : "sun.max",
                     label: scheme == .dark ? "Switch to light" : "Switch to dark", on: false) {
                prefs.look = scheme == .dark ? .light : .dark
            }
            .contextMenu {
                Button("Light") { prefs.look = .light }
                Button("Dark") { prefs.look = .dark }
                Button("Like the Mac") { prefs.look = .system }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
    }
}

private struct FootIcon: View {
    let symbol: String
    let label: String
    let on: Bool
    let action: () -> Void
    @XState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on || hovering ? Theme.text : Theme.textMuted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(on || hovering ? Theme.raised : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .xoolFocus(radius: Theme.Radius.row, action: action)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - the shortcuts popover

/// Inside the column, right over the foot: the real keys, in groups, as key
/// caps. Esc or a click elsewhere closes it.
struct ShortcutsPopover: View {
    @ObservedObject private var ui = XoolUI.shared
    @FocusState private var focused: Bool
    @XState private var frame: CGRect = .zero
    @XState private var monitor: Any?

    struct Item: Identifiable { let id = UUID(); let title: String; let keys: [String] }
    struct Group: Identifiable { let id: String; let items: [Item] }

    /// The keys as they stand now (Settings › Shortcuts can move them), from
    /// the same commands the menus are made of.
    static func groups() -> [Group] {
        let store = ShortcutStore.shared
        func command(_ id: String, _ title: String? = nil) -> Item? {
            guard let c = Command.named(id), let key = store.key(for: id) else { return nil }
            return Item(title: title ?? c.title.replacingOccurrences(of: "…", with: ""), keys: caps(key.display))
        }
        func fixed(_ title: String, _ keys: String) -> Item { Item(title: title, keys: caps(keys)) }
        return [
            Group(id: "Navigation", items: [
                command("tabs.back"), command("tabs.forward"), command("view.reload"),
                command("file.openAddress", "Address"), command("edit.find", "Find on page"),
            ].compactMap { $0 }),
            Group(id: "Tabs", items: [
                command("file.newTab"), command("file.closeTab"), command("file.reopen", "Reopen tab"),
                command("tabs.next"), command("tabs.previous"), command("tabs.search", "Search tabs"),
            ].compactMap { $0 }),
            Group(id: "Agents", items: [
                fixed("Agents panel", "⇧⌘A"), fixed("Agent 1–9", "⌥1…9"),
            ]),
            Group(id: "Brain", items: [
                command("brain.open", "Show Brain"), command("brain.savePage", "Save page"),
                fixed("Mention an entry", "@"),
            ].compactMap { $0 }),
            Group(id: "Voice", items: [
                fixed("Push to talk", "fn"), fixed("Talk, other key", "⌥Space"),
            ]),
        ]
    }

    /// "⇧⌘T" → ["⇧", "⌘", "T"]: one cap per modifier and one for the key.
    static func caps(_ display: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var result: [String] = []
        var rest = ""
        for ch in display {
            if modifiers.contains(ch), rest.isEmpty { result.append(String(ch)) } else { rest.append(ch) }
        }
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard shortcuts").font(Theme.heading).foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.m).padding(.bottom, Theme.Space.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(Self.groups()) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.id).font(Theme.font(Theme.Size.caption, Theme.Weight.label)).foregroundStyle(Theme.textMuted)
                                .padding(.bottom, 2)
                            ForEach(group.items) { item in
                                HStack(spacing: 6) {
                                    Text(item.title).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                                    Spacer(minLength: 4)
                                    HStack(spacing: 3) { ForEach(Array(item.keys.enumerated()), id: \.offset) { KeyCap(text: $0.element) } }
                                }
                                .frame(minHeight: 20)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.title), \(item.keys.joined(separator: " "))")
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.m)
            }
            .frame(maxHeight: 600)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous).strokeBorder(Theme.line))
        .background(GeometryReader { geo in Color.clear.onAppear { frame = geo.frame(in: .global) }.onChange(of: geo.frame(in: .global)) { _, f in frame = f } })
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) { ui.closeKeys(); return .handled }
        .onAppear {
            focused = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let window = event.window, let content = window.contentView else { return event }
                let p = event.locationInWindow
                let point = CGPoint(x: p.x, y: content.bounds.height - p.y)
                if !frame.insetBy(dx: -1, dy: -1).contains(point) { ui.closeKeys() }
                return event
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.line))
    }
}
