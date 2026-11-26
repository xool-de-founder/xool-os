import SwiftUI
import UniformTypeIdentifiers

/// "Brain" in the column: opens the list; files dropped on it are kept.
struct SidebarBrain: View {
    static let height: CGFloat = 30
    @ObservedObject private var ui = XoolUI.shared
    @ObservedObject private var store = BrainStore.shared
    @XState private var targeted = false

    var body: some View {
        XoolButton(action: { ui.toggleBrain() }) {
            HStack(spacing: 8) {
                Image(systemName: "brain").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ui.showBrain ? Theme.text : Theme.textMuted).frame(width: 16).accessibilityHidden(true)
                Text("Brain").font(Theme.body).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if store.working > 0 { ProgressView().controlSize(.mini) }
                else if !store.items.isEmpty { Text("\(store.items.count)").font(Theme.caption).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        }
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(targeted || ui.showBrain ? Theme.raised : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(targeted ? Theme.focus : Color.clear, lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { BrainView.drop($0); return true }
        .accessibilityLabel("Brain, \(store.items.count) entries")
        .help("Everything you keep, searchable. Drop files here")
    }
}
