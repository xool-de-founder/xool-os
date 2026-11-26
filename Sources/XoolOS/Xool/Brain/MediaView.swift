import SwiftUI

/// Media: the Brain's pictures, video and audio, as a grid of previews
/// (docs/PLAN.md 6, F). The same store, a different filter; the entry
/// picked opens on the right as in the Brain.
struct MediaView: View {
    @ObservedObject var ui: XoolUI
    let browser: Browser
    @ObservedObject private var store = BrainStore.shared
    @XState private var type: MediaType?
    @XState private var targeted = false
    @XState private var picked: String?

    private var media: [BrainItem] { store.items.filter(\.isMedia) }
    private var shown: [BrainItem] { media.filter { type == nil || $0.mediaType == type } }
    private var selected: BrainItem? { picked.flatMap { id in media.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Theme.line.frame(height: 1)
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let item = selected {
                    Theme.line.frame(width: 1)
                    BrainPreview(item: item, store: store)
                        .id(item.id + item.status)
                        .frame(width: 380)
                }
            }
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                    .strokeBorder(Theme.focus, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.focus.opacity(0.06)).padding(Theme.Space.s).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { BrainView.drop($0); return true }
        .onKeyPress(.escape) { ui.showMedia = false; return .handled }
        .transition(Motion.reduced ? .identity : .opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media")
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "photo.on.rectangle").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).accessibilityHidden(true)
            Text("Media").font(Theme.title).foregroundStyle(Theme.text)
            Text("\(media.count) kept").font(Theme.small).foregroundStyle(Theme.textMuted)
            HStack(spacing: Theme.Space.xs) {
                chip("All", nil, media.count)
                ForEach(MediaType.allCases) { t in chip(t.title, t, media.filter { $0.mediaType == t }.count) }
            }
            .padding(.leading, Theme.Space.m)
            Spacer(minLength: 0)
            XoolButton(action: chooseFiles) {
                Label("Add files", systemImage: "plus").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.m)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
            XoolIconButton(symbol: "xmark", label: "Close Media") { ui.showMedia = false }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.m)
    }

    private func chip(_ title: String, _ value: MediaType?, _ count: Int) -> some View {
        let on = type == value
        return XoolButton(radius: Theme.Radius.chip, action: { type = value }) {
            Text("\(title) \(count)").font(Theme.small).foregroundStyle(on ? Theme.text : Theme.textMuted).padding(.horizontal, Theme.Space.s)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(on ? Theme.raised : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(on ? Theme.line : Color.clear))
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if media.isEmpty {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.faint).accessibilityHidden(true)
                Text("Drop pictures, video or audio here").font(Theme.heading).foregroundStyle(Theme.text)
                Text("They are kept on this Mac, with their previews. Pictures are read for their words.")
                    .font(Theme.small).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center).frame(maxWidth: 280)
                XoolButton(action: chooseFiles) {
                    Label("Choose files", systemImage: "plus").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.m)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
            }
            .padding(Theme.Space.xl)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])).padding(Theme.Space.m))
        } else if shown.isEmpty {
            Text("No \(type?.title.lowercased() ?? "media") yet.").font(Theme.body).foregroundStyle(Theme.textMuted)
                .padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                    ForEach(shown) { tile($0) }
                }
                .padding(Theme.Space.xl)
            }
        }
    }

    private func tile(_ item: BrainItem) -> some View {
        let on = picked == item.id
        return Button { picked = on ? nil : item.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(Theme.surface)
                    if let image = store.thumbnail(item) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: item.mediaType?.symbol ?? "doc").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.faint)
                    }
                    if item.indexing { ProgressView().controlSize(.small) }
                    if item.mediaType == .video || item.mediaType == .audio {
                        Image(systemName: item.mediaType == .video ? "play.fill" : "waveform")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 26, height: 26).background(Circle().fill(Theme.canvas.opacity(0.8)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
                    }
                }
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(on ? Theme.focus : Theme.line, lineWidth: on ? 2 : 1))
                Text(item.title).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xoolFocus(radius: Theme.Radius.row) { picked = on ? nil : item.id }
        .accessibilityLabel("\(item.mediaType?.title ?? "Media") \(item.title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .movie, .audio]
        panel.prompt = "Add to Media"
        if panel.runModal() == .OK { store.add(panel.urls) }
    }
}
