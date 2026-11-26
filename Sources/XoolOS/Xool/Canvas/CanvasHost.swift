import AppKit
import SwiftUI
import WebKit

/// Every canvas page that is alive, by document id. A page is rebuilt from the
/// saved document when its tab comes back to the front, so one is only kept a
/// short while after it leaves the screen.
@MainActor
final class CanvasHosts {
    static let shared = CanvasHosts()
    private(set) var live: [String: CanvasController] = [:]

    func controller(for id: String) -> CanvasController {
        if let existing = live[id] { existing.cancelEviction(); return existing }
        let made = CanvasController(id: id)
        live[id] = made
        return made
    }

    func evict(_ id: String) {
        live[id]?.shutDown()
        live[id] = nil
    }

    /// Titles in the tab row follow a rename made anywhere.
    func titleChanged(_ id: String) {
        for browser in Browsers.all {
            if let tab = browser.tabs.first(where: { $0.page?.kind == .canvas && $0.page?.detail == id }) {
                tab.show(InternalPage(.canvas, id), stepping: false)
                browser.objectWillChange.send()
            }
        }
    }

    func flushAll() { for c in live.values { c.flush() } }
}

/// One canvas page: the web view, the bridge to it and the files it asks for.
@MainActor
final class CanvasController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let id: String
    let webView: WKWebView
    private var ready = false
    private var pendingReplace: String?
    private var appearance: NSKeyValueObservation?
    private var eviction: DispatchWorkItem?
    /// Test runs: what `canvasjs` printed, and what the page said with `log`.
    var logLines: [String] = []

    init(id: String) {
        self.id = id
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let user = WKUserContentController()
        config.userContentController = user
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Before the view is made: it takes a copy of the configuration.
        config.setURLSchemeHandler(CanvasFiles(), forURLScheme: CanvasStore.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        user.add(WeakHandler(self), name: "xool")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        Web.inspectable(webView)
        webView.setAccessibilityLabel("Canvas")
        appearance = webView.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.pushTheme() }
        }
        webView.load(URLRequest(url: URL(string: "\(CanvasStore.scheme)://app/index.html")!))
    }

    func shutDown() {
        appearance = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "xool")
        webView.stopLoading()
    }

    // MARK: to the page

    func pushTheme() {
        guard ready else { return }
        let vars = CanvasTheme.variables(for: webView.effectiveAppearance)
        call("XoolCanvas.setTheme(vars)", ["vars": vars])
    }

    func replace(_ json: String) {
        guard ready else { return }
        call("XoolCanvas.replace(json)", ["json": json])
    }

    func setTitle(_ title: String) {
        guard ready else { return }
        call("XoolCanvas.setTitle(title)", ["title": title])
    }

    func flush() {
        guard ready else { return }
        call("XoolCanvas.flush()", [:])
    }

    func call(_ script: String, _ arguments: [String: Any]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    /// Test runs: JavaScript in the page, its result in `logLines`.
    func run(_ script: String, then done: @escaping (String) -> Void) {
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): done("\(value)")
            case .failure(let error): done("error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let store = CanvasStore.shared
        func answer(_ value: Any) {
            guard let req = body["req"] as? Int else { return }
            call("XoolCanvas.resolve(req, value)", ["req": req, "value": value])
        }
        switch type {
        case "ready":
            ready = true
            pushTheme()
            let doc = store.load(id).map { CanvasDoc.serialize($0) }
            call("XoolCanvas.load(json)", ["json": doc ?? NSNull()])
        case "save":
            if let json = body["json"] as? String { store.save(id, json: json) }
        case "title":
            if let title = body["title"] as? String, !title.isEmpty {
                // The page has it already; the tab row and the Brain follow.
                if var doc = store.load(id) {
                    doc["title"] = title
                    store.save(id, json: CanvasDoc.serialize(doc))
                    CanvasHosts.shared.titleChanged(id)
                }
            }
        case "asset":
            let url = store.saveAsset(id, dataURL: body["data"] as? String ?? "", name: body["name"] as? String ?? "image")
            answer(url ?? (body["data"] as? String ?? ""))
        case "brainSearch":
            let query = (body["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let own = id
            Task { @MainActor in
                var found: [BrainItem]
                if query.isEmpty {
                    found = Array(BrainStore.shared.items.filter { !$0.isMedia && $0.id != own }.prefix(8))
                } else {
                    found = await BrainStore.shared.search(query, limit: 8).map(\.item).filter { $0.id != own }
                }
                answer(found.map { ["id": $0.id, "title": $0.title, "kind": $0.kind.one] })
            }
        case "openBrain":
            if let target = body["id"] as? String { BrainStore.shared.show(target) }
        case "openURL":
            if let url = (body["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? "") {
                Browsers.acting.open(url, foreground: true)
            }
        case "ask":
            CanvasAsk.open(canvas: id, question: body["question"] as? String ?? "", context: body["context"] as? String ?? "")
        case "log":
            logLines.append(body["text"] as? String ?? "")
        default: break
        }
    }

    // A link is never followed inside the canvas: it opens as a tab of the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.scheme == CanvasStore.scheme { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { Browsers.acting.open(url, foreground: true) }
    }

    // MARK: leaving the screen

    func scheduleEviction() {
        flush()
        eviction?.cancel()
        let work = DispatchWorkItem { [id] in CanvasHosts.shared.evict(id) }
        eviction = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    func cancelEviction() { eviction?.cancel(); eviction = nil }
}

/// The page's files: the bundle at `xool-canvas://app/<file>`, a document's pictures at
/// `xool-canvas://asset/<id>/<file>`. Nothing else is served, and nothing goes to the network.
final class CanvasFiles: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        // `xool-canvas://app/<file>`: the bundle; `xool-canvas://asset/<id>/<file>`: a picture of a document.
        let host = url.host() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        var file: URL?
        if host == "app" {
            let root = CanvasBundle.folder
            let name = parts.isEmpty ? "index.html" : parts.joined(separator: "/")
            let candidate = root.appendingPathComponent(name).standardizedFileURL
            if candidate.path.hasPrefix(root.standardizedFileURL.path + "/") { file = candidate }
        } else if host == "asset", parts.count == 2, !parts[0].contains(".."), !parts[1].contains("..") {
            file = MainActor.assumeIsolated { CanvasStore.shared.assets(parts[0]).appendingPathComponent(parts[1]) }
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        var headers = ["Content-Type": CanvasBundle.mime(file.pathExtension), "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        if host == "app" {
            // The page reaches nothing but its own files: no network, no remote pictures.
            headers["Content-Security-Policy"] = "default-src 'none'; script-src xool-canvas:; style-src xool-canvas: 'unsafe-inline'; img-src xool-canvas: data: blob:; font-src xool-canvas: data:; connect-src 'none'; base-uri 'none'; form-action 'none'"
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

}

/// A message handler that does not keep its controller alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Where the page's files are: in the app bundle; next to the sources when run from a build folder.
enum CanvasBundle {
    static let folder: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("canvas"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) { return bundled }
        // swift run / debug builds: Resources/canvas in the repository.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Resources/canvas")
    }()

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic": return "image/heic"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

/// The app's tokens (Theme.swift) as CSS variables, resolved for the appearance the page is in.
enum CanvasTheme {
    static func variables(for appearance: NSAppearance) -> [String: String] {
        var out: [String: String] = [:]
        let tokens: [(String, NSColor)] = [
            ("canvas", Theme.NS.canvas), ("surface", Theme.NS.surface), ("raised", Theme.NS.raised), ("line", Theme.NS.line),
            ("text", Theme.NS.text), ("text-muted", Theme.NS.textMuted), ("focus", Theme.NS.focus), ("hover", Theme.NS.hover), ("faint", Theme.NS.faint),
        ]
        appearance.performAsCurrentDrawingAppearance {
            for (name, color) in tokens {
                guard let c = color.usingColorSpace(.sRGB) else { continue }
                out[name] = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            }
        }
        out["scheme"] = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        out["font"] = (Theme.family.map { "\"\($0)\", " } ?? "") + "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, sans-serif"
        return out
    }
}

/// The canvas inside the tab: the page's web view, kept by the controller while it is on screen.
struct CanvasPage: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let controller = CanvasHosts.shared.controller(for: id)
        controller.webView.removeFromSuperview()
        return controller.webView
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        if let web = view as? WKWebView, let controller = CanvasHosts.shared.live.values.first(where: { $0.webView === web }) {
            controller.scheduleEviction()
        }
    }
}

/// "Ask agent" in the `/` menu: the front thread's agent (or the first) gets the question,
/// with the canvas and the block as context, in a thread of its own.
@MainActor
enum CanvasAsk {
    static func open(canvas id: String, question: String, context: String) {
        let ui = XoolUI.shared, store = AgentStore.shared
        let browser = Browsers.acting
        guard let agent = ui.front.flatMap({ store.thread($0)?.agentID }) ?? store.agents.first?.id else {
            browser.announce("No agent yet. Add one with + below, then ask again")
            return
        }
        let title = BrainStore.shared.item(id)?.title ?? "canvas"
        let thread = store.newThread(for: agent)
        var extra = "The user is writing on the canvas “\(title)” (id \(id)), and asked from inside a text block. "
        extra += "Read the canvas with canvas_read, and add to it with canvas_add_block (Markdown) or canvas_add_frame. "
        if !context.isEmpty { extra += "The block they asked from reads:\n\(String(context.prefix(4000)))" }
        ChatRuntime.shared.extra[thread.id] = extra
        ui.openThread(thread.id)
        let text = question.isEmpty ? (context.isEmpty ? "" : "Help me with this block.") : question
        if !text.isEmpty { ChatRuntime.shared.send(text, in: thread.id) }
    }
}
