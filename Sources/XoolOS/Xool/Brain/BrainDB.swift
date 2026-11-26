import Foundation
import SQLite3

/// `Float` is Xool's own type (Float.swift: floating video) in this module.
typealias F32 = Swift.Float

/// What kind of thing a Brain entry is.
enum BrainKind: String, CaseIterable, Identifiable, Codable {
    case note, file, page, bookmark, skill
    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "Notes"
        case .file: return "Files"
        case .page: return "Pages"
        case .bookmark: return "Bookmarks"
        case .skill: return "Skills"
        }
    }

    var one: String {
        switch self {
        case .note: return "Note"
        case .file: return "File"
        case .page: return "Saved page"
        case .bookmark: return "Bookmark"
        case .skill: return "Skill"
        }
    }

    var symbol: String {
        switch self {
        case .note: return "note.text"
        case .file: return "doc"
        case .page: return "doc.richtext"
        case .bookmark: return "bookmark"
        case .skill: return "wand.and.stars"
        }
    }
}

struct BrainItem: Identifiable, Equatable {
    var id: String
    var kind: BrainKind
    var title: String
    /// The page or bookmark's address.
    var url: String?
    /// The original, under the Brain's files folder (relative).
    var file: String?
    var size: Int64 = 0
    var created = Date()
    var updated = Date()
    /// ready, indexing or failed.
    var status = "ready"
    /// What went wrong, or how it was read ("OCR", "PDF").
    var note: String?
    /// Skills and bookmarks live elsewhere; this is their key there.
    var link: String?
    var excerpt = ""
    /// A file's symbol by what it is; the kind's otherwise.
    var symbol: String {
        guard kind == .file, let ext = file.map({ ($0 as NSString).pathExtension.lowercased() }) else { return kind.symbol }
        if ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"].contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.richtext" }
        if ["xlsx", "csv", "numbers", "tsv"].contains(ext) { return "tablecells" }
        if ["swift", "py", "js", "ts", "json", "sh", "html", "css"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }
    var indexing: Bool { status == "indexing" }
    /// Where an entry is opened from anywhere: a link in an answer.
    var address: String { "xool-brain://" + id }
}

/// SQLite with FTS5 (the system's, no package): entries, their text and the
/// vectors of their text's pieces. One serial queue; every call is quick.
final class BrainDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "xool.brain.db")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: URL) {
        queue.sync {
            guard sqlite3_open(path.path, &db) == SQLITE_OK else { db = nil; return }
            sqlite3_busy_timeout(db, 3000)
            _ = exec("PRAGMA journal_mode=WAL")
            _ = exec("PRAGMA synchronous=NORMAL")
            _ = exec("""
                CREATE TABLE IF NOT EXISTS items(
                  id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, url TEXT, file TEXT,
                  size INTEGER DEFAULT 0, created REAL, updated REAL, status TEXT DEFAULT 'ready',
                  note TEXT, link TEXT, text TEXT DEFAULT '');
                CREATE UNIQUE INDEX IF NOT EXISTS items_link ON items(link) WHERE link IS NOT NULL;
                CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(id UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2');
                CREATE TABLE IF NOT EXISTS chunks(item TEXT NOT NULL, n INTEGER NOT NULL, text TEXT NOT NULL, vec BLOB, PRIMARY KEY(item, n));
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
                """)
        }
    }

    var usable: Bool { queue.sync { db != nil } }

    // MARK: plumbing

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String, _ binds: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, value) in binds.enumerated() {
            let at = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, at, text, -1, Self.transient)
            case let number as Int: sqlite3_bind_int64(statement, at, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, at, number)
            case let number as Double: sqlite3_bind_double(statement, at, number)
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, at, $0.baseAddress, Int32(data.count), Self.transient) }
            default: sqlite3_bind_null(statement, at)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ binds: [Any?] = []) -> Bool {
        guard let statement = prepare(sql, binds) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func rows<T>(_ sql: String, _ binds: [Any?] = [], _ map: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, binds) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(map(statement)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    private static let columns = "id, kind, title, url, file, size, created, updated, status, note, link, substr(text, 1, 240)"

    private static func item(_ s: OpaquePointer) -> BrainItem {
        BrainItem(id: text(s, 0) ?? "", kind: BrainKind(rawValue: text(s, 1) ?? "") ?? .note, title: text(s, 2) ?? "",
                  url: text(s, 3), file: text(s, 4), size: sqlite3_column_int64(s, 5),
                  created: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
                  updated: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                  status: text(s, 8) ?? "ready", note: text(s, 9), link: text(s, 10),
                  excerpt: (text(s, 11) ?? "").replacingOccurrences(of: "\n", with: " "))
    }

    // MARK: entries

    /// Inserts or replaces an entry and its text (the index follows).
    func put(_ item: BrainItem, text: String) {
        queue.sync {
            exec("BEGIN")
            run("""
                INSERT INTO items(id, kind, title, url, file, size, created, updated, status, note, link, text)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title, url=excluded.url, file=excluded.file,
                  size=excluded.size, updated=excluded.updated, status=excluded.status, note=excluded.note, link=excluded.link, text=excluded.text
                """, [item.id, item.kind.rawValue, item.title, item.url, item.file, item.size, item.created.timeIntervalSince1970,
                      item.updated.timeIntervalSince1970, item.status, item.note, item.link, text])
            run("DELETE FROM fts WHERE id = ?", [item.id])
            run("INSERT INTO fts(id, title, body) VALUES(?,?,?)", [item.id, item.title, text])
            exec("COMMIT")
        }
    }

    func setStatus(_ id: String, _ status: String, note: String? = nil) {
        queue.sync { _ = run("UPDATE items SET status = ?, note = COALESCE(?, note) WHERE id = ?", [status, note, id]) }
    }

    func remove(_ id: String) {
        queue.sync {
            run("DELETE FROM items WHERE id = ?", [id])
            run("DELETE FROM fts WHERE id = ?", [id])
            run("DELETE FROM chunks WHERE item = ?", [id])
        }
    }

    func list(kind: BrainKind? = nil, limit: Int = 2000) -> [BrainItem] {
        queue.sync {
            if let kind {
                return rows("SELECT \(Self.columns) FROM items WHERE kind = ? ORDER BY updated DESC LIMIT ?", [kind.rawValue, limit], Self.item)
            }
            return rows("SELECT \(Self.columns) FROM items ORDER BY updated DESC LIMIT ?", [limit], Self.item)
        }
    }

    func item(_ id: String) -> BrainItem? {
        queue.sync { rows("SELECT \(Self.columns) FROM items WHERE id = ?", [id], Self.item).first }
    }

    func item(link: String) -> BrainItem? {
        queue.sync { rows("SELECT \(Self.columns) FROM items WHERE link = ?", [link], Self.item).first }
    }

    func text(_ id: String) -> String {
        queue.sync { rows("SELECT text FROM items WHERE id = ?", [id]) { Self.text($0, 0) ?? "" }.first ?? "" }
    }

    func count() -> Int {
        queue.sync { rows("SELECT count(*) FROM items", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    /// Titles starting with or containing what is typed: the `@` menu.
    func titles(matching typed: String, limit: Int) -> [BrainItem] {
        queue.sync {
            let like = "%" + typed.replacingOccurrences(of: "%", with: "") + "%"
            return rows("SELECT \(Self.columns) FROM items WHERE title LIKE ? ORDER BY updated DESC LIMIT ?", [like, limit], Self.item)
        }
    }

    // MARK: full text

    /// FTS5's phrase syntax kept out of the way: each word is a prefix term,
    /// any of them may match, and the best-matching entries come first.
    static func ftsQuery(_ typed: String) -> String? {
        let all = typed.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        // Little words match everything: left out, unless nothing else is left.
        let content = all.filter { $0.count > 2 && !Self.stopwords.contains($0.lowercased()) }
        let words = content.isEmpty ? all : content
        guard !words.isEmpty else { return nil }
        return words.prefix(12).map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "what", "how", "was", "are", "you", "from", "have", "not", "can", "does",
        "der", "die", "das", "und", "ist", "ein", "eine", "einen", "wie", "was", "wer", "wo", "ich", "mir", "mich", "wir", "sie",
        "nicht", "noch", "mit", "von", "für", "auf", "dem", "den", "des", "zum", "zur", "oder", "aber", "auch", "muss", "kann", "wird",
    ]

    func search(_ typed: String, kind: BrainKind?, limit: Int) -> [(id: String, snippet: String)] {
        guard let match = Self.ftsQuery(typed) else { return [] }
        return queue.sync {
            var sql = """
                SELECT fts.id, snippet(fts, 2, '', '', '…', 16), snippet(fts, 1, '', '', '…', 12)
                FROM fts JOIN items ON items.id = fts.id
                WHERE fts MATCH ?
                """
            var binds: [Any?] = [match]
            if let kind { sql += " AND items.kind = ?"; binds.append(kind.rawValue) }
            // Title matches count double.
            sql += " ORDER BY bm25(fts, 0.0, 4.0, 1.0) LIMIT ?"
            binds.append(limit)
            return rows(sql, binds) { s in
                let body = Self.text(s, 1) ?? ""
                let title = Self.text(s, 2) ?? ""
                return (Self.text(s, 0) ?? "", body.isEmpty ? title : body)
            }
        }
    }

    // MARK: vectors

    func setChunks(_ id: String, texts: [String]) {
        queue.sync {
            exec("BEGIN")
            run("DELETE FROM chunks WHERE item = ?", [id])
            for (n, text) in texts.enumerated() { run("INSERT INTO chunks(item, n, text) VALUES(?,?,?)", [id, n, text]) }
            exec("COMMIT")
        }
    }

    func pendingChunks(limit: Int) -> [(item: String, n: Int, text: String)] {
        queue.sync {
            rows("SELECT item, n, text FROM chunks WHERE vec IS NULL LIMIT ?", [limit]) {
                (Self.text($0, 0) ?? "", Int(sqlite3_column_int($0, 1)), Self.text($0, 2) ?? "")
            }
        }
    }

    func pendingCount() -> Int {
        queue.sync { rows("SELECT count(*) FROM chunks WHERE vec IS NULL", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    func setVectors(_ updates: [(item: String, n: Int, vec: [F32])]) {
        queue.sync {
            exec("BEGIN")
            for update in updates {
                let data = update.vec.withUnsafeBufferPointer { Data(buffer: $0) }
                run("UPDATE chunks SET vec = ? WHERE item = ? AND n = ?", [data, update.item, update.n])
            }
            exec("COMMIT")
        }
    }

    func allVectors() -> [(item: String, text: String, vec: [F32])] {
        queue.sync {
            rows("SELECT item, text, vec FROM chunks WHERE vec IS NOT NULL", []) { s in
                let count = Int(sqlite3_column_bytes(s, 2)) / MemoryLayout<F32>.size
                var vec = [F32](repeating: 0, count: count)
                if count > 0, let raw = sqlite3_column_blob(s, 2) { memcpy(&vec, raw, count * MemoryLayout<F32>.size) }
                return (Self.text(s, 0) ?? "", Self.text(s, 1) ?? "", vec)
            }
        }
    }

    func clearVectors() { queue.sync { _ = run("UPDATE chunks SET vec = NULL") } }

    func meta(_ key: String) -> String? {
        queue.sync { rows("SELECT value FROM meta WHERE key = ?", [key]) { Self.text($0, 0) }.first ?? nil }
    }

    func setMeta(_ key: String, _ value: String) {
        queue.sync { _ = run("INSERT INTO meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value]) }
    }
}
