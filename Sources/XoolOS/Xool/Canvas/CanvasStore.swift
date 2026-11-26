import AppKit
import Foundation

/// Canvas documents in the Brain (kind "Canvas"): one folder per document
/// under `Brain/files/<id>/` with `canvas.json` and the pictures in `assets/`.
/// What is written on a canvas is indexed like any note (words and meaning).
@MainActor
final class CanvasStore {
    static let shared = CanvasStore()
    static let scheme = "xool-canvas"

    private var brain: BrainStore { BrainStore.shared }

    func file(_ id: String) -> URL { brain.filesFolder.appendingPathComponent(id).appendingPathComponent("canvas.json") }
    func assets(_ id: String) -> URL { brain.filesFolder.appendingPathComponent(id).appendingPathComponent("assets", isDirectory: true) }

    func exists(_ id: String) -> Bool { brain.item(id)?.kind == .canvas }

    /// A new, empty canvas (or one that starts with `doc`).
    @discardableResult
    func create(title: String = "Untitled canvas", doc: CanvasJSON? = nil) -> BrainItem {
        var doc = doc ?? CanvasDoc.empty(title: title)
        doc["title"] = title
        let json = CanvasDoc.serialize(doc)
        return brain.saveCanvas(id: nil, title: title, json: json, text: CanvasDoc.text(doc))
    }

    func load(_ id: String) -> CanvasJSON? {
        guard exists(id), let text = try? String(contentsOf: file(id), encoding: .utf8) else { return nil }
        return CanvasDoc.parse(text)
    }

    /// What the page sent: kept as is, its words indexed.
    func save(_ id: String, json: String) {
        guard exists(id) else { return }
        let doc = CanvasDoc.parse(json)
        let title = (doc["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? brain.item(id)?.title ?? "Untitled canvas"
        brain.saveCanvas(id: id, title: title, json: json, text: CanvasDoc.text(doc))
    }

    func rename(_ id: String, to title: String) {
        guard var doc = load(id) else { return }
        doc["title"] = title
        let json = CanvasDoc.serialize(doc)
        brain.saveCanvas(id: id, title: title, json: json, text: CanvasDoc.text(doc))
        CanvasHosts.shared.live[id]?.setTitle(title)
        CanvasHosts.shared.titleChanged(id)
    }

    /// An agent's (or any code's) change to a canvas, open or not: applied to the saved document,
    /// and handed to the page if it is showing, which keeps its view and lets Undo step back.
    func change<T>(_ id: String, _ edit: (inout CanvasJSON) -> T) -> T? {
        guard var doc = load(id) else { return nil }
        // The page may hold edits it has not saved yet.
        let result = edit(&doc)
        let json = CanvasDoc.serialize(doc)
        brain.saveCanvas(id: id, title: doc["title"] as? String ?? "Untitled canvas", json: json, text: CanvasDoc.text(doc))
        CanvasHosts.shared.live[id]?.replace(json)
        return result
    }

    /// A picture dropped or chosen in the page, kept next to the document. Returns the address the page shows it by.
    func saveAsset(_ id: String, dataURL: String, name: String) -> String? {
        guard exists(id), dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.startIndex..<comma]
        guard header.contains(";base64"), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        let mime = header.dropFirst(5).split(separator: ";").first.map(String.init) ?? "image/png"
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg", "image/heic": "heic"][mime] ?? "png"
        let stem = BrainStore.fileName(((name as NSString).deletingPathExtension)).replacingOccurrences(of: " ", with: "-")
        let file = "\(BrainStore.newID())-\(stem.prefix(40)).\(ext)"
        let folder = assets(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try data.write(to: folder.appendingPathComponent(file)) } catch { return nil }
        return "\(Self.scheme)://asset/\(id)/\(file)"
    }

    // MARK: opening

    /// The canvas as a tab of the window in front: one tab per document.
    func open(_ id: String, in window: Browser? = nil) {
        let browser = window ?? Browsers.acting
        guard exists(id) else { browser.announce("That canvas is no longer in the Brain"); return }
        XoolUI.shared.showBrain = false
        XoolUI.shared.showMedia = false
        browser.show(InternalPage(.canvas, id))
    }

    /// File › New Canvas, ⌘K: an empty one, open and ready.
    @discardableResult
    func newCanvas(in browser: Browser? = nil) -> BrainItem {
        let item = create()
        open(item.id, in: browser)
        return item
    }

    /// Test runs: a canvas made through the same calls as the agent tools (a frame with blocks), opened.
    func launchDemo() {
        let item = create(title: "Launch plan")
        _ = change(item.id) { doc in
            let frame = CanvasDoc.addFrame(&doc, name: "Week 1", x: nil, y: nil, w: nil, h: nil)
            _ = CanvasDoc.addBlock(&doc, markdown: "# Launch week\n\nThree things before Friday:\n\n- [ ] Write the announcement\n- [x] Pick the date\n- [ ] Ask the **press list**", frame: frame, x: nil, y: nil, width: nil)
            _ = CanvasDoc.addBlock(&doc, markdown: "> Ship small, ship often.\n\n```\nswift build -c release\n```", frame: frame, x: nil, y: nil, width: nil)
            let second = CanvasDoc.addFrame(&doc, name: "Ideas", x: nil, y: nil, w: 360, h: 260)
            _ = CanvasDoc.addBlock(&doc, markdown: "## Later\n\n| Idea | Owner |\n|---|---|\n| Newsletter | Ana |\n| Demo video | Ben |", frame: second, x: nil, y: nil, width: nil)
        }
        open(item.id)
    }
}
