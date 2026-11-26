import SwiftUI
import UniformTypeIdentifiers

/// "Sources" in the column (docs/PLAN.md 6, F; 8, B): Brain (everything
/// written), Bookmarks, Media (pictures, video, audio). Each with its icon
/// and its name; quiet `text-muted`, `text` while it is the one open.
struct SidebarResources: View {
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 22
    static let height: CGFloat = headerHeight + 3 * rowHeight
    /// Under Media, before the foot: 20 pt to the Settings row, whose own
    /// row is centred in the foot's 36 (4 pt of it above).
    static let footGap: CGFloat = 16

    @ObservedObject var browser: Browser
    @ObservedObject private var ui = XoolUI.shared
    @ObservedObject private var store = BrainStore.shared
    @XState private var brainTargeted = false
    @XState private var mediaTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Quieter than its rows: 11 pt, 550, `text-muted` at 70 %.
            Text("Sources")
                .font(Theme.font(Theme.Size.caption, Theme.Weight.label))
                .foregroundStyle(Theme.textMuted.opacity(0.7))
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 8)
                .frame(height: Self.headerHeight, alignment: .leading)
            ResourceRow(symbol: "brain", title: "Brain", on: ui.showBrain, targeted: brainTargeted,
                        trailing: store.working > 0 ? .working : .count(store.items.filter { !$0.isMedia }.count),
                        label: "Brain, \(store.items.filter { !$0.isMedia }.count) entries",
                        help: "Everything written, searchable. Drop files here") { ui.toggleBrain() }
                .onDrop(of: [.fileURL], isTargeted: $brainTargeted) { BrainView.drop($0); return true }
            ResourceRow(symbol: browser.bookmarksOpen ? "bookmark.fill" : "bookmark", title: "Bookmarks", on: browser.bookmarksOpen,
                        targeted: false, trailing: .none, label: "Bookmarks", help: "Bookmarks") { browser.toggleBookmarks() }
                .popover(isPresented: $browser.bookmarksOpen, hangingFrom: .trailing) {
                    if let id = browser.bookmarkCard {
                        BookmarkCard(browser: browser, bookmarks: browser.bookmarks, id: id)
                    } else {
                        BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                    }
                }
            ResourceRow(symbol: "photo.on.rectangle", title: "Media", on: ui.showMedia, targeted: mediaTargeted,
                        trailing: .count(store.items.filter(\.isMedia).count),
                        label: "Media, \(store.items.filter(\.isMedia).count) entries",
                        help: "Pictures, video and audio. Drop files here") { ui.toggleMedia() }
                .onDrop(of: [.fileURL], isTargeted: $mediaTargeted) { BrainView.drop($0); return true }
        }
    }
}

private struct ResourceRow: View {
    enum Trailing: Equatable { case none, working, count(Int) }
    let symbol: String
    let title: String
    let on: Bool
    let targeted: Bool
    let trailing: Trailing
    let label: String
    let help: String
    let action: () -> Void
    @XState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on || hovering ? Theme.text : Theme.textMuted).frame(width: 16).accessibilityHidden(true)
                Text(title).font(Theme.body).foregroundStyle(on || hovering ? Theme.text : Theme.textMuted)
                Spacer(minLength: 0)
                switch trailing {
                case .working: ProgressView().controlSize(.mini)
                case .count(let n) where n > 0: Text("\(n)").font(Theme.caption).foregroundStyle(Theme.textMuted)
                default: EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: SidebarResources.rowHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(height: SidebarResources.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(targeted || on || hovering ? Theme.raised : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(targeted ? Theme.focus : Color.clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .animation(Theme.motion(Theme.hoverTime), value: hovering)
        .xoolFocus(radius: Theme.Radius.row, action: action)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(help)
    }
}
