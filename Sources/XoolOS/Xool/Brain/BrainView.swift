import SwiftUI
import UniformTypeIdentifiers

/// The Brain: a Linear-style list of everything kept — filtered by kind,
/// searched by words and meaning — with the entry's preview on the right.
/// Files are dropped in anywhere on it.
struct BrainView: View {
    @ObservedObject var ui: XoolUI
    let browser: Browser
    @ObservedObject private var store = BrainStore.shared
    @ObservedObject private var embedder = BrainEmbedder.shared
    @ObservedObject private var catalog = OllamaCatalog.shared
    @XState private var query = ""
    @XState private var kind: BrainKind?
    @XState private var hits: [BrainHit]?
    @XState private var searchTask: Task<Void, Never>?
    @XState private var targeted = false
    @XState private var draftTitle = ""
    @XState private var draftText = ""
    @XState private var writing = false
    @FocusState private var searching: Bool

    private var shown: [BrainItem] {
        store.items.filter { kind == nil || $0.kind == kind }
    }

    private var selected: BrainItem? { store.selection.flatMap { id in store.items.first { $0.id == id } ?? store.item(id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Theme.line.frame(height: 1)
            setupNote
            HStack(spacing: 0) {
                list.frame(width: 380)
                Theme.line.frame(width: 1)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                    .strokeBorder(Theme.focus, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.focus.opacity(0.06))
                    .padding(Theme.Space.s)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in BrainView.drop(providers); return true }
        .onAppear {
            searching = true
            store.syncSkills()
            store.syncBookmarks(browser.bookmarks)
            Task { await embedder.refresh(); store.startEmbedding() }
        }
        .onKeyPress(.escape) { ui.showBrain = false; return .handled }
        .transition(Motion.reduced ? .identity : .opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Brain")
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "brain").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).accessibilityHidden(true)
                Text("Brain").font(Theme.title).foregroundStyle(Theme.text)
                Text(status).font(Theme.small).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                XoolButton(action: { writing = true; draftTitle = ""; draftText = ""; store.selection = nil }) {
                    Label("New note", systemImage: "square.and.pencil").font(Theme.label).foregroundStyle(Theme.text)
                        .padding(.horizontal, Theme.Space.m)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                XoolButton(action: chooseFiles) {
                    Label("Add files", systemImage: "plus").font(Theme.label).foregroundStyle(Theme.text)
                        .padding(.horizontal, Theme.Space.m)
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                XoolIconButton(symbol: "xmark", label: "Close Brain") { ui.showBrain = false }
            }
            HStack(spacing: Theme.Space.m) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textMuted).accessibilityHidden(true)
                    TextField("Search words or meaning", text: $query).textFieldStyle(.plain).font(Theme.body).focused($searching)
                        .accessibilityLabel("Search the Brain")
                        .onChange(of: query) { _, _ in schedule() }
                        .onSubmit { schedule(now: true) }
                }
                .padding(.horizontal, Theme.Space.m).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(searching ? Theme.focus : Theme.line, lineWidth: searching ? 2 : 1))
                .frame(maxWidth: 380)
                chips
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.m)
    }

    private var chips: some View {
        HStack(spacing: Theme.Space.xs) {
            chip("All", nil)
            ForEach(BrainKind.allCases) { chip($0.title, $0) }
        }
    }

    private func chip(_ title: String, _ value: BrainKind?) -> some View {
        let on = kind == value
        let count = value.map { k in store.items.filter { $0.kind == k }.count } ?? store.items.count
        return XoolButton(radius: Theme.Radius.chip, action: { kind = value; schedule(now: true) }) {
            Text("\(title) \(count)").font(Theme.small).foregroundStyle(on ? Theme.text : Theme.textMuted)
                .padding(.horizontal, Theme.Space.s)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(on ? Theme.raised : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(on ? Theme.line : Color.clear))
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var status: String {
        var parts = ["\(store.items.count) kept"]
        if store.working > 0 { parts.append("reading \(store.working)") }
        if store.pending > 0, embedder.ready { parts.append("indexing meaning, \(store.pending) left") }
        return parts.joined(separator: " · ")
    }

    /// What is missing for search by meaning, and the button for it.
    @ViewBuilder
    private var setupNote: some View {
        if let pull = catalog.pull, pull.name == embedder.model {
            HStack(spacing: Theme.Space.m) {
                if let failed = pull.failed {
                    Label(failed, systemImage: "exclamationmark.triangle").font(Theme.small).foregroundStyle(Theme.text)
                    XoolButton(action: { catalog.dismissFailure() }) { Text("Dismiss").font(Theme.label).padding(.horizontal, Theme.Space.s) }
                } else {
                    ProgressView(value: pull.total > 0 ? pull.fraction : nil).frame(width: 160).accessibilityLabel("Downloading \(pull.name)")
                    Text("\(pull.name): \(pull.status)").font(Theme.small).foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.s)
            .background(Theme.hover)
            Theme.line.frame(height: 1)
        } else if let note = embedder.note {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "info.circle").foregroundStyle(Theme.textMuted).accessibilityHidden(true)
                Text(note).font(Theme.small).foregroundStyle(Theme.text)
                if case .missing = embedder.status {
                    XoolButton(action: { embedder.pull() }) {
                        Label("Download \(embedder.model)", systemImage: "arrow.down.circle").font(Theme.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, Theme.Space.m)
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                } else {
                    XoolButton(action: { Task { await embedder.refresh() } }) { Text("Check again").font(Theme.label).padding(.horizontal, Theme.Space.m) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.s)
            .background(Theme.hover)
            Theme.line.frame(height: 1)
        }
    }

    // MARK: list

    @ViewBuilder
    private var list: some View {
        let searched = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if store.items.isEmpty && !writing {
            emptyState
        } else if searched, let hits {
            if hits.isEmpty {
                Text("Nothing in the Brain matches “\(query)”.").font(Theme.body).foregroundStyle(Theme.textMuted).padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(hits) { row($0.item, snippet: $0.snippet, hit: $0) } }.padding(Theme.Space.xs)
                }
            }
        } else if shown.isEmpty {
            Text("No \(kind?.title.lowercased() ?? "entries") yet.").font(Theme.body).foregroundStyle(Theme.textMuted).padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(shown) { row($0, snippet: nil, hit: nil) } }.padding(Theme.Space.xs)
            }
        }
    }

    private func row(_ item: BrainItem, snippet: String?, hit: BrainHit?) -> some View {
        let on = store.selection == item.id
        return XoolButton(action: { writing = false; store.selection = item.id }) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: item.kind.symbol).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .frame(width: 18, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Theme.label).foregroundStyle(Theme.text).lineLimit(1)
                    Text(snippet ?? subtitle(item)).font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(snippet == nil ? 1 : 2)
                }
                Spacer(minLength: 0)
                if item.indexing { ProgressView().controlSize(.small).accessibilityLabel("Reading") }
                else if item.status == "failed" { Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
                else if let hit, hit.byMeaning, !hit.byText {
                    Text("meaning").font(Theme.caption).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(on ? Theme.raised : Color.clear))
        .accessibilityLabel("\(item.kind.one) \(item.title)\(item.indexing ? ", reading" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func subtitle(_ item: BrainItem) -> String {
        var parts = [item.kind.one]
        if let host = item.url.flatMap({ URL(string: $0)?.host() }) { parts.append(host) }
        if item.size > 0, item.kind == .file { parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
        parts.append(item.updated.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.faint).accessibilityHidden(true)
            Text("Drop files here").font(Theme.heading).foregroundStyle(Theme.text)
            Text("PDFs, pictures, notes, code, Office files. They are read on this Mac and found by their words and meaning. Agents can use them.")
                .font(Theme.small).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center).frame(maxWidth: 280)
            XoolButton(action: chooseFiles) {
                Label("Choose files", systemImage: "plus").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.m)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])).padding(Theme.Space.m))
    }

    // MARK: preview

    @ViewBuilder
    private var preview: some View {
        if writing {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("Title", text: $draftTitle).textFieldStyle(.plain).font(Theme.title).accessibilityLabel("Note title")
                TextEditor(text: $draftText).font(Theme.body).scrollContentBackground(.hidden)
                    .padding(Theme.Space.s).background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                    .accessibilityLabel("Note text")
                HStack {
                    XoolButton(action: saveDraft) { Text("Save note").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.m) }
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                    XoolButton(action: { writing = false }) { Text("Cancel").font(Theme.label).foregroundStyle(Theme.textMuted).padding(.horizontal, Theme.Space.m) }
                }
            }
            .padding(Theme.Space.xl)
        } else if let item = selected {
            BrainPreview(item: item, store: store)
                .id(item.id + item.updated.description + item.status)
        } else {
            Text(store.items.isEmpty ? "" : "Pick an entry to see it here.").font(Theme.body).foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: actions

    private func schedule(now: Bool = false) {
        searchTask?.cancel()
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { hits = nil; return }
        let filter = kind
        searchTask = Task { @MainActor in
            if !now { try? await Task.sleep(nanoseconds: 220_000_000) }
            guard !Task.isCancelled else { return }
            // Words first, at once; meaning joins when its vector is there.
            hits = await store.search(typed, kind: filter, limit: 30, meaning: false)
            guard !Task.isCancelled else { return }
            let both = await store.search(typed, kind: filter, limit: 30)
            if !Task.isCancelled { hits = both }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add to Brain"
        if panel.runModal() == .OK { store.add(panel.urls) }
    }

    private func saveDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !text.isEmpty else { writing = false; return }
        let made = store.saveNote(title: title.isEmpty ? String(text.prefix(40)) : title, text: text)
        writing = false
        store.selection = made.id
    }

    /// Files from a drop, wherever it lands.
    static func drop(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let link = item as? URL { url = link }
                guard let url else { return }
                DispatchQueue.main.async { BrainStore.shared.add([url]) }
            }
        }
    }
}

/// An entry on the right: its picture, what it is, its words, what can be done.
private struct BrainPreview: View {
    let item: BrainItem
    @ObservedObject var store: BrainStore
    @XState private var text = ""
    @XState private var editing = false
    @XState private var title = ""
    @XState private var body_ = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(Theme.title).foregroundStyle(Theme.text).textSelection(.enabled)
                        Text(meta).font(Theme.small).foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                actions
                if let note = item.note, item.status != "ready" || item.kind == .file {
                    Label(note, systemImage: item.status == "failed" ? "exclamationmark.triangle" : "info.circle")
                        .font(Theme.small).foregroundStyle(Theme.textMuted)
                }
                if let image = store.thumbnail(item), item.kind == .file {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 420, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                        .accessibilityLabel("Preview of \(item.title)")
                }
                if editing {
                    TextField("Title", text: $title).textFieldStyle(.plain).font(Theme.heading)
                    TextEditor(text: $body_).font(Theme.body).frame(minHeight: 220).scrollContentBackground(.hidden)
                        .padding(Theme.Space.s).background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                    HStack {
                        XoolButton(action: saveEdit) { Text("Save").font(Theme.label).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.m) }
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
                        XoolButton(action: { editing = false }) { Text("Cancel").font(Theme.label).foregroundStyle(Theme.textMuted).padding(.horizontal, Theme.Space.m) }
                    }
                } else if !text.isEmpty {
                    Text(String(text.prefix(6000)) + (text.count > 6000 ? "\n…" : ""))
                        .font(Theme.body).foregroundStyle(Theme.text).textSelection(.enabled)
                } else if item.kind == .bookmark {
                    Text(item.url ?? "").font(Theme.body).foregroundStyle(Theme.textMuted).textSelection(.enabled)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { text = store.text(of: item.id) }
    }

    private var meta: String {
        var parts = [item.kind.one]
        if let host = item.url.flatMap({ URL(string: $0)?.host() }) { parts.append(host) }
        if item.kind == .file, item.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) }
        parts.append("kept " + item.created.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            if item.url != nil || item.kind == .file || item.kind == .skill {
                button(item.url != nil ? "Open page" : item.kind == .skill ? "Open skills folder" : "Open", "arrow.up.forward.square") { store.open(item) }
            }
            if item.kind == .file { button("Show in Finder", "folder") { store.reveal(item) } }
            if item.kind == .note || item.kind == .page {
                button("Edit", "pencil") { title = item.title; body_ = text; editing = true }
            }
            button("Copy link", "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(item.title)](\(item.address))", forType: .string)
            }
            if item.kind != .skill, item.kind != .bookmark {
                button("Delete", "trash") { store.remove(item.id); store.selection = nil }
            }
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        XoolButton(action: action) {
            Label(title, systemImage: symbol).font(Theme.small).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.s)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.line))
    }

    private func saveEdit() {
        store.saveNote(title: title.isEmpty ? item.title : title, text: body_, kind: item.kind, url: item.url, link: item.link, id: item.id)
        editing = false
        text = body_
    }
}
