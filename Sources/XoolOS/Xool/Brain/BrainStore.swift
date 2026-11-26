import AppKit
import Foundation

struct BrainHit: Identifiable, Equatable {
    var item: BrainItem
    var snippet: String
    /// Found by its words, by its meaning, or both.
    var byText: Bool
    var byMeaning: Bool
    var cosine: F32 = 0
    var id: String { item.id }
}

/// The second brain: everything kept in one place under
/// `Application Support/Xool/Brain` — the originals as files, the index in
/// SQLite. Documents, any file, notes, saved pages; skills and bookmarks are
/// listed from where they live, not copied. Nothing here leaves this Mac.
@MainActor
final class BrainStore: ObservableObject {
    static let shared = BrainStore()

    let folder: URL
    let filesFolder: URL
    let thumbsFolder: URL
    let db: BrainDB

    @Published private(set) var items: [BrainItem] = []
    /// Files being read right now, and pieces waiting for their vectors.
    @Published private(set) var working = 0
    @Published private(set) var pending = 0
    /// A line about the last add that didn't work out.
    @Published var notice: String?
    /// The entry the Brain view should show (a link, `@`, ⌘K).
    @Published var selection: String?
    private var embedding = false
    /// Test runs: what the Brain view's field starts with.
    var launchQuery: String?

    init(folder: URL = Store.folder.appendingPathComponent("Brain", isDirectory: true)) {
        self.folder = folder
        filesFolder = folder.appendingPathComponent("files", isDirectory: true)
        thumbsFolder = folder.appendingPathComponent("thumbs", isDirectory: true)
        let manager = FileManager.default
        for dir in [folder, filesFolder, thumbsFolder] { try? manager.createDirectory(at: dir, withIntermediateDirectories: true) }
        db = BrainDB(path: folder.appendingPathComponent("brain.sqlite"))
        // What was being read when the app quit starts again.
        reload()
        for item in items where item.indexing { db.setStatus(item.id, "failed", note: "Interrupted. Add it again") }
        reload()
        syncSkills()
        pending = db.pendingCount()
    }

    func reload() { items = db.list() }

    var skillsFolderNote: String { "Skills are read from Xool/skills" }

    // MARK: adding

    static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10)) }

    /// Files and folders dropped or chosen: copied in, read in the
    /// background, found by their words as soon as that is done.
    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let next = walker?.nextObject() as? URL, files.count < 300 {
                    if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(next) }
                }
            } else {
                files.append(url)
            }
        }
        for url in files { addFile(url) }
    }

    private func addFile(_ source: URL) {
        let id = Self.newID()
        let name = source.lastPathComponent
        let relative = id + "/" + name
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let item = BrainItem(id: id, kind: .file, title: source.deletingPathExtension().lastPathComponent, file: relative, size: size, status: "indexing")
        db.put(item, text: "")
        working += 1
        reload()
        let destination = filesFolder.appendingPathComponent(relative)
        let thumb = thumbsFolder.appendingPathComponent(id + ".png")
        let db = db
        Task.detached(priority: .utility) { [weak self] in
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: destination)
            } catch {
                db.setStatus(id, "failed", note: "Couldn't copy it: \(error.localizedDescription)")
                await self?.finished()
                return
            }
            let read = await Ingest.extract(destination)
            _ = await Ingest.thumbnail(destination, to: thumb)
            var done = item
            done.status = "ready"
            done.note = read.text.isEmpty ? "No words found in it. It is kept, but only its name can be found" : read.how
            done.updated = Date()
            db.put(done, text: read.text)
            db.setChunks(id, texts: Ingest.chunks(title: done.title, text: read.text))
            await self?.finished(embed: true)
        }
    }

    private func finished(embed: Bool = false) {
        working = max(0, working - 1)
        reload()
        pending = db.pendingCount()
        if embed { startEmbedding() }
    }

    /// A note, or an agent's save: kept as a Markdown file as well.
    @discardableResult
    func saveNote(title: String, text: String, kind: BrainKind = .note, url: String? = nil, link: String? = nil, id replacing: String? = nil) -> BrainItem {
        var existing = replacing.flatMap { db.item($0) } ?? link.flatMap { db.item(link: $0) }
        let id = existing?.id ?? Self.newID()
        let name = Self.fileName(title) + ".md"
        let relative = id + "/" + name
        let body = (url.map { "<\($0)>\n\n" } ?? "") + text
        let dir = filesFolder.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = existing?.file, old != relative { try? FileManager.default.removeItem(at: filesFolder.appendingPathComponent(old)) }
        try? ("# " + title + "\n\n" + body).write(to: filesFolder.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        existing = existing ?? BrainItem(id: id, kind: kind, title: title)
        var item = existing!
        item.kind = kind
        item.title = title
        item.url = url
        item.file = relative
        item.link = link
        item.size = Int64(body.utf8.count)
        item.updated = Date()
        item.status = "ready"
        item.note = nil
        db.put(item, text: text)
        db.setChunks(id, texts: Ingest.chunks(title: title, text: text))
        reload()
        pending = db.pendingCount()
        startEmbedding()
        return db.item(id) ?? item
    }

    /// The page in `tab`, as Reading Mode reads it: its words and address.
    func savePage(of tab: Tab, announce: @escaping (String) -> Void) {
        guard tab.isWeb, let address = tab.pageAddress, ["http", "https"].contains(address.scheme?.lowercased() ?? "") else {
            announce("Only web pages can be saved to the Brain")
            return
        }
        if tab.shy { announce("A private tab isn't saved to the Brain"); return }
        Task { @MainActor [weak self] in
            guard let read = await AIPage.read(tab) else { announce("Nothing to save on this page"); return }
            let title = read.title.isEmpty ? (address.host() ?? address.absoluteString) : read.title
            let item = self?.saveNote(title: title, text: read.text, kind: .page, url: address.absoluteString, link: "page:" + address.absoluteString)
            announce(item == nil ? "Couldn't save the page" : "Saved to the Brain: \(title)")
        }
    }

    static func fileName(_ title: String) -> String {
        let clean = title.map { "/:\\?*\"<>|\n".contains($0) ? "-" : $0 }
        let name = String(clean).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled" : String(name.prefix(80))
    }

    func remove(_ id: String) {
        guard let item = db.item(id), item.kind != .skill, item.kind != .bookmark else { return }
        if let file = item.file { try? FileManager.default.removeItem(at: filesFolder.appendingPathComponent(file).deletingLastPathComponent()) }
        try? FileManager.default.removeItem(at: thumbsFolder.appendingPathComponent(id + ".png"))
        db.remove(id)
        reload()
        pending = db.pendingCount()
    }

    func rename(_ id: String, to title: String) {
        guard var item = db.item(id), item.kind == .note || item.kind == .file || item.kind == .page else { return }
        let text = db.text(id)
        item.title = title
        item.updated = Date()
        db.put(item, text: text)
        reload()
    }

    // MARK: linked kinds

    /// Skills are listed from `Xool/skills`; their text is the SKILL.md.
    func syncSkills() {
        let skills = SkillStore.shared.skills
        let keep = Set(skills.map { "skill:" + $0.name })
        for item in db.list(kind: .skill) where !keep.contains(item.link ?? "") { db.remove(item.id) }
        for skill in skills {
            let link = "skill:" + skill.name
            let old = db.item(link: link)
            let text = skill.description + "\n\n" + skill.body
            if let old, db.text(old.id) == text { continue }
            let item = BrainItem(id: old?.id ?? Self.newID(), kind: .skill, title: skill.name, created: old?.created ?? Date(), link: link)
            db.put(item, text: text)
            db.setChunks(item.id, texts: Ingest.chunks(title: skill.name, text: text))
        }
        reload()
        pending = db.pendingCount()
        startEmbedding()
    }

    /// Bookmarks are listed from the browser's own list: the address and
    /// the name are all there is, and a change there is a change here.
    func syncBookmarks(_ bookmarks: Bookmarks) {
        var found: [(String, URL)] = []
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                if let children = node.children { walk(children) }
                else if let url = node.address { found.append((node.label, url)) }
            }
        }
        walk(bookmarks.roots)
        let keep = Set(found.map { "bm:" + $0.1.absoluteString })
        for item in db.list(kind: .bookmark) where !keep.contains(item.link ?? "") { db.remove(item.id) }
        var changed = false
        for (title, url) in found {
            let link = "bm:" + url.absoluteString
            let old = db.item(link: link)
            if let old, old.title == title { continue }
            let item = BrainItem(id: old?.id ?? Self.newID(), kind: .bookmark, title: title, url: url.absoluteString, created: old?.created ?? Date(), link: link)
            let text = title + "\n" + (url.host() ?? "") + "\n" + url.absoluteString
            db.put(item, text: text)
            db.setChunks(item.id, texts: [text])
            changed = true
        }
        reload()
        if changed { pending = db.pendingCount(); startEmbedding() }
    }

    // MARK: vectors

    /// Gives every waiting piece its vector, a few at a time, as long as
    /// Ollama and the model are there. Quietly stops when they aren't.
    func startEmbedding() {
        guard !embedding, db.pendingCount() > 0 else { return }
        embedding = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { embedding = false; pending = db.pendingCount() }
            let embedder = BrainEmbedder.shared
            if embedder.status == .unknown || !embedder.ready { await embedder.refresh() }
            guard embedder.ready else { return }
            // A different model's vectors don't compare with these.
            if db.meta("embedModel") != embedder.model {
                if db.meta("embedModel") != nil { db.clearVectors() }
                db.setMeta("embedModel", embedder.model)
            }
            while true {
                let batch = db.pendingChunks(limit: 16)
                if batch.isEmpty { break }
                guard let vectors = await embedder.embed(batch.map(\.text), query: false) else { break }
                db.setVectors(zip(batch, vectors).map { (item: $0.item, n: $0.n, vec: $1) })
                pending = db.pendingCount()
            }
        }
    }

    // MARK: finding

    /// Words and meaning together: FTS5's best matches and the pieces whose
    /// vector is nearest the question's, merged by rank.
    func search(_ typed: String, kind: BrainKind? = nil, limit: Int = 12, meaning: Bool = true) async -> [BrainHit] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let words = db.search(query, kind: kind, limit: 40)
        var near: [(id: String, snippet: String, cosine: F32)] = []
        if meaning {
            let embedder = BrainEmbedder.shared
            if embedder.status == .unknown { await embedder.refresh() }
            if embedder.ready, let q = await embedder.embed([query], query: true)?.first {
                var best: [String: (text: String, cosine: F32)] = [:]
                for piece in db.allVectors() where piece.vec.count == q.count {
                    var dot: F32 = 0
                    for i in 0..<q.count { dot += piece.vec[i] * q[i] }
                    if dot >= Self.minCosine, dot > (best[piece.item]?.cosine ?? -1) { best[piece.item] = (piece.text, dot) }
                }
                // Only what is near the nearest: a model's scores sit close
                // together, and the rest is noise.
                let top = best.values.map(\.cosine).max() ?? 0
                let ranked = best.filter { $0.value.cosine >= max(Self.minCosine, top - 0.07) }.sorted { $0.value.cosine > $1.value.cosine }.prefix(30)
                near = ranked.map { (id: $0.key, snippet: $0.value.text, cosine: $0.value.cosine) }
            }
        }
        var score: [String: Double] = [:]
        var snippet: [String: String] = [:]
        var viaText = Set<String>(), viaMeaning = Set<String>()
        var cosines: [String: F32] = [:]
        for (rank, hit) in words.enumerated() {
            score[hit.id, default: 0] += 1 / Double(60 + rank)
            snippet[hit.id] = hit.snippet
            viaText.insert(hit.id)
        }
        for (rank, hit) in near.enumerated() {
            score[hit.id, default: 0] += 1 / Double(60 + rank)
            if snippet[hit.id] == nil { snippet[hit.id] = String(hit.snippet.prefix(220)) }
            viaMeaning.insert(hit.id)
            cosines[hit.id] = hit.cosine
        }
        var hits: [BrainHit] = []
        for (id, _) in score.sorted(by: { $0.value > $1.value }) {
            guard let item = db.item(id), kind == nil || item.kind == kind else { continue }
            hits.append(BrainHit(item: item, snippet: (snippet[id] ?? item.excerpt).replacingOccurrences(of: "\n", with: " "),
                                 byText: viaText.contains(id), byMeaning: viaMeaning.contains(id), cosine: cosines[id] ?? 0))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// Test runs: after the files are read, search and write what was found
    /// (words, and words with meaning) to a file.
    func logSearch(_ typed: String, to path: String) {
        Task { @MainActor in
            while working > 0 || items.contains(where: \.indexing) { try? await Task.sleep(nanoseconds: 300_000_000) }
            await BrainEmbedder.shared.refresh()
            startEmbedding()
            for _ in 0..<120 where pending > 0 && BrainEmbedder.shared.ready { try? await Task.sleep(nanoseconds: 500_000_000); pending = db.pendingCount() }
            var out = "embedder: \(BrainEmbedder.shared.status)\npending: \(pending)\n"
            for (label, meaning, typed) in typed.components(separatedBy: ";;").flatMap({ q in [("words", false, q), ("words+meaning", true, q)] }) {
                let started = Date()
                let found = await search(typed, limit: 8, meaning: meaning)
                out += "\n== \(label) (\(Int(Date().timeIntervalSince(started) * 1000)) ms) for “\(typed)”\n"
                for hit in found { out += "\(hit.item.kind.rawValue) | \(hit.item.title) | text=\(hit.byText) meaning=\(hit.byMeaning) cos=\(String(format: "%.2f", Double(hit.cosine))) | \(hit.snippet.prefix(90))\n" }
            }
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// How near in meaning counts as related. Unrelated texts sit around
    /// 0.4–0.55 with nomic-embed-text on short German texts; related ones above.
    static let minCosine: F32 = 0.5

    func text(of id: String) -> String { db.text(id) }
    func item(_ id: String) -> BrainItem? { db.item(id) }

    func fileURL(_ item: BrainItem) -> URL? {
        item.file.map { filesFolder.appendingPathComponent($0) }
    }

    func thumbnail(_ item: BrainItem) -> NSImage? {
        NSImage(contentsOf: thumbsFolder.appendingPathComponent(item.id + ".png"))
    }

    // MARK: opening

    /// Shows an entry in the Brain view.
    func show(_ id: String) {
        selection = id
        XoolUI.shared.showBrain = true
        XoolUI.shared.showAgents = false
        XoolUI.shared.showTabs = false
    }

    /// An address or a file opened where it belongs.
    func open(_ item: BrainItem) {
        if let address = item.url.flatMap({ URL(string: $0) }) {
            Browsers.acting.open(address, foreground: true)
            XoolUI.shared.showBrain = false
        } else if item.kind == .skill {
            NSWorkspace.shared.open(SkillStore.shared.folder)
        } else if let url = fileURL(item) {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ item: BrainItem) {
        if let url = fileURL(item) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// `xool-brain://id`, in a link of an answer or a mention.
    static func id(from url: URL) -> String? {
        url.scheme == "xool-brain" ? (url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) : nil
    }
}
