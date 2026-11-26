import SwiftUI
import WebKit

/// ⇧⌘\: every tab as a card with a picture, typing filters, several can be
/// picked to close. Tabs an agent works in come first, ringed in its colour.
struct TabsOverview: View {
    @ObservedObject var browser: Browser
    @ObservedObject var ui: XoolUI
    @XState private var query = ""
    @XState private var picked: Set<Tab.ID> = []
    @FocusState private var searching: Bool

    private var tabs: [Tab] {
        browser.tabs.filter { tab in
            query.isEmpty || tab.title.localizedCaseInsensitiveContains(query)
                || (tab.pageAddress?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func section(_ title: String, _ list: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("\(title) · \(list.count)").font(Theme.label).foregroundStyle(Theme.textMuted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                ForEach(list, id: \.id) { tab in card(tab) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Text("Tabs").font(Theme.title).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    TextField("Filter tabs", text: $query).textFieldStyle(.plain).font(Theme.body).focused($searching)
                        .accessibilityLabel("Filter tabs")
                }
                .padding(.horizontal, Theme.Space.m).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(searching ? Theme.focus : Theme.line, lineWidth: searching ? 2 : 1))
                .frame(maxWidth: 320)
                Spacer()
                if !picked.isEmpty {
                    XoolButton(action: closePicked) {
                        Label("Close \(picked.count)", systemImage: "xmark").font(Theme.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, Theme.Space.m)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                }
                XoolIconButton(symbol: "xmark", label: "Close tabs overview") { ui.showTabs = false }
            }
            if tabs.isEmpty {
                Text(browser.tabs.isEmpty ? "No tabs open. ⌘T opens one." : "No tab matches “\(query)”.")
                    .font(Theme.body).foregroundStyle(Theme.textMuted)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        let working = tabs.filter(\.agentWorking)
                        if !working.isEmpty { section("Agents", working) }
                        section(working.isEmpty ? "All tabs" : "Other tabs", tabs.filter { !$0.agentWorking })
                    }
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 28)
        .background(Theme.canvas)
        .onAppear { searching = true }
        .onKeyPress(.escape) { ui.showTabs = false; return .handled }
        .transition(Motion.reduced ? .identity : .opacity)
    }

    private func closePicked() {
        for tab in browser.tabs where picked.contains(tab.id) { browser.close(tab) }
        picked = []
    }

    private func card(_ tab: Tab) -> some View {
        let on = picked.contains(tab.id)
        let toggle = { if on { picked.remove(tab.id) } else { picked.insert(tab.id) } }
        return Button {
            if NSEvent.modifierFlags.contains(.command) || !picked.isEmpty { toggle() }
            else { browser.select(tab); ui.showTabs = false }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                TabThumbnail(tab: tab).frame(height: 110).clipped()
                HStack(spacing: 6) {
                    if let icon = tab.icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    else { Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tab.title.isEmpty ? "New tab" : tab.title).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                        Text(tab.pageAddress?.host() ?? "").font(Theme.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12)).foregroundStyle(on ? Theme.text : Theme.faint)
                        .onTapGesture(perform: toggle)
                        .accessibilityHidden(true)
                }
                .padding(Theme.Space.s)
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                .strokeBorder(tab.agentWorking ? AgentColor.violet.solid : (on ? Theme.focus : Theme.line),
                              lineWidth: tab.agentWorking || on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .xoolFocus(radius: Theme.Radius.popover) { browser.select(tab); ui.showTabs = false }
        .accessibilityLabel("\(tab.title.isEmpty ? "New tab" : tab.title), \(tab.pageAddress?.host() ?? "")\(on ? ", selected" : "")")
    }
}

/// A picture of the page, taken when the card appears; none for a tab that
/// holds no page yet.
struct TabThumbnail: View {
    let tab: Tab
    @XState private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.raised
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc.richtext").font(.system(size: 22)).foregroundStyle(Theme.faint)
            }
        }
        .onAppear {
            guard image == nil, let web = tab.built else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 420
            web.takeSnapshot(with: config) { picture, _ in
                DispatchQueue.main.async { image = picture }
            }
        }
        .accessibilityHidden(true)
    }
}
