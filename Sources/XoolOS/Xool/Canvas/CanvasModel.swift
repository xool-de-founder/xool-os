import Foundation

/// A canvas document as the page keeps it (web/canvas/src/types.ts), handled
/// here as plain JSON so an agent can change a canvas that is not open, and
/// the search index can read what is written on it.
///
///     { version, title, view?, elements: [ { id, type, x, y, w, h, name?, doc?, src?, from?, to? } ] }
///
/// A text element's `doc` is a block document (TipTap / ProseMirror JSON).
typealias CanvasJSON = [String: Any]

enum CanvasDoc {
    static func empty(title: String) -> CanvasJSON {
        ["version": 1, "title": title, "elements": [CanvasJSON]()]
    }

    static func parse(_ text: String) -> CanvasJSON {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? CanvasJSON else { return empty(title: "Untitled canvas") }
        return object
    }

    static func serialize(_ doc: CanvasJSON) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func elements(_ doc: CanvasJSON) -> [CanvasJSON] { doc["elements"] as? [CanvasJSON] ?? [] }

    static func number(_ el: CanvasJSON, _ key: String) -> Double {
        if let d = el[key] as? Double { return d }
        if let i = el[key] as? Int { return Double(i) }
        return (el[key] as? NSNumber)?.doubleValue ?? 0
    }

    static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(9)) }

    // MARK: reading

    /// Every word on the canvas: its title, its frames' names and the text of its blocks.
    static func text(_ doc: CanvasJSON) -> String {
        var parts: [String] = []
        if let title = doc["title"] as? String { parts.append(title) }
        for el in elements(doc) {
            if el["type"] as? String == "frame", let name = el["name"] as? String { parts.append(name) }
            if el["type"] as? String == "text", let body = el["doc"] as? CanvasJSON {
                let t = plain(body).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// The text of a block document, one block per line.
    static func plain(_ node: CanvasJSON) -> String {
        if let text = node["text"] as? String { return text }
        let children = node["content"] as? [CanvasJSON] ?? []
        let type = node["type"] as? String ?? ""
        let inner = children.map(plain)
        switch type {
        case "doc", "bulletList", "orderedList", "taskList", "table", "blockquote", "listItem", "taskItem": return inner.joined(separator: "\n")
        case "tableRow": return inner.joined(separator: " | ")
        case "horizontalRule": return "---"
        case "paragraph", "heading", "codeBlock", "tableCell", "tableHeader": return inner.joined()
        default: return inner.joined()
        }
    }

    /// An outline for an agent: the frames and what is in them, with ids.
    static func outline(_ doc: CanvasJSON, limit: Int = 12000) -> String {
        let els = elements(doc)
        var lines = ["Canvas “\(doc["title"] as? String ?? "Untitled")”: \(els.count) elements"]
        func box(_ e: CanvasJSON) -> String { "at \(Int(number(e, "x"))),\(Int(number(e, "y"))) size \(Int(abs(number(e, "w"))))×\(Int(abs(number(e, "h"))))" }
        let frames = els.filter { $0["type"] as? String == "frame" }
        var shown = Set<String>()
        for frame in frames {
            lines.append("\nFrame [\(frame["id"] as? String ?? "")] “\(frame["name"] as? String ?? "")” \(box(frame))")
            for child in inside(frame, els) {
                shown.insert(child["id"] as? String ?? "")
                lines.append(describe(child, indent: "  "))
            }
        }
        let loose = els.filter { !shown.contains($0["id"] as? String ?? "") && $0["type"] as? String != "frame" }
        if !loose.isEmpty { lines.append("\nOutside any frame:") }
        for el in loose { lines.append(describe(el, indent: "  ")) }
        let out = lines.joined(separator: "\n")
        return out.count > limit ? String(out.prefix(limit)) + "\n[… cut]" : out
    }

    private static func describe(_ el: CanvasJSON, indent: String) -> String {
        let id = el["id"] as? String ?? ""
        let type = el["type"] as? String ?? ""
        switch type {
        case "text":
            let body = (el["doc"] as? CanvasJSON).map(plain) ?? ""
            return "\(indent)Text [\(id)]:\n" + body.split(separator: "\n", omittingEmptySubsequences: false).map { indent + "  " + $0 }.joined(separator: "\n")
        case "image": return "\(indent)Image [\(id)] \(el["name"] as? String ?? "")"
        case "connector": return "\(indent)Connector [\(id)] from \(el["from"] as? String ?? "") to \(el["to"] as? String ?? "")"
        default: return "\(indent)\(type.capitalized) [\(id)]"
        }
    }

    /// Elements whose centre lies inside a frame.
    static func inside(_ frame: CanvasJSON, _ els: [CanvasJSON]) -> [CanvasJSON] {
        let fx = number(frame, "x"), fy = number(frame, "y"), fw = number(frame, "w"), fh = number(frame, "h")
        let id = frame["id"] as? String
        return els.filter { e in
            guard e["id"] as? String != id, e["type"] as? String != "connector" else { return false }
            let cx = number(e, "x") + number(e, "w") / 2, cy = number(e, "y") + number(e, "h") / 2
            return cx >= fx && cx <= fx + fw && cy >= fy && cy <= fy + fh
        }
    }

    // MARK: changing

    /// A frame, after the last one (or at the place given). Returns its id.
    @discardableResult
    static func addFrame(_ doc: inout CanvasJSON, name: String, x: Double?, y: Double?, w: Double?, h: Double?) -> String {
        var els = elements(doc)
        let frames = els.filter { $0["type"] as? String == "frame" }
        let right = frames.map { number($0, "x") + number($0, "w") }.max()
        let id = newID()
        els.append(["id": id, "type": "frame", "name": name.isEmpty ? "Frame \(frames.count + 1)" : name,
                    "x": x ?? (right.map { $0 + 80 } ?? 0), "y": y ?? frames.map { number($0, "y") }.min() ?? 0,
                    "w": max(120, w ?? 520), "h": max(80, h ?? 360)] as CanvasJSON)
        doc["elements"] = els
        return id
    }

    /// Blocks written as Markdown, as one text element: inside the frame (below what is there already,
    /// the frame growing if it must), or free on the surface. Returns the new element's id.
    static func addBlock(_ doc: inout CanvasJSON, markdown: String, frame: String?, x: Double?, y: Double?, width: Double?) -> String? {
        let blocks = Markdown.blocks(markdown)
        guard !blocks.isEmpty else { return nil }
        var els = elements(doc)
        let id = newID()
        let lines = estimatedLines(blocks)
        var el: CanvasJSON = ["id": id, "type": "text", "doc": ["type": "doc", "content": blocks] as CanvasJSON]
        if let frame, let at = els.firstIndex(where: { $0["id"] as? String == frame || ($0["type"] as? String == "frame" && ($0["name"] as? String)?.lowercased() == frame.lowercased()) }) {
            var f = els[at]
            let fx = number(f, "x"), fy = number(f, "y"), fw = number(f, "w")
            let kids = inside(f, els)
            let bottom = kids.map { number($0, "y") + number($0, "h") }.max()
            let w = width ?? max(120, fw - 48)
            let h = Double(lines) * 22 + 20
            let top = bottom.map { $0 + 16 } ?? fy + 24
            el["x"] = x ?? fx + 24; el["y"] = y ?? top; el["w"] = w; el["h"] = h
            if (y ?? top) + h + 24 > fy + number(f, "h") {
                f["h"] = (y ?? top) + h + 24 - fy
                els[at] = f
            }
        } else {
            let texts = els.filter { $0["type"] as? String != "connector" }
            let bottom = texts.map { number($0, "y") + number($0, "h") }.max()
            el["x"] = x ?? 0; el["y"] = y ?? bottom.map { $0 + 24 } ?? 0
            el["w"] = width ?? 320; el["h"] = Double(lines) * 22 + 20
        }
        els.append(el)
        doc["elements"] = els
        return id
    }

    private static func estimatedLines(_ blocks: [CanvasJSON]) -> Int {
        blocks.reduce(0) { n, b in
            let t = plain(b)
            return n + max(1, t.split(separator: "\n", omittingEmptySubsequences: false).count) + (b["type"] as? String == "heading" ? 1 : 0)
        }
    }

    // MARK: Markdown → blocks

    /// A small, forgiving reader: headings, lists, to-dos, quotes, code, rules, tables, paragraphs,
    /// and `**bold**`, `*italic*`, `` `code` `` and `[links](…)` inside them.
    enum Markdown {
        static func blocks(_ source: String) -> [CanvasJSON] {
            let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            var out: [CanvasJSON] = []
            var i = 0
            func paragraph(_ text: String) -> CanvasJSON { ["type": "paragraph", "content": inline(text)] }
            while i < lines.count {
                let raw = lines[i]
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { i += 1; continue }
                if line.hasPrefix("```") {
                    var code: [String] = []
                    i += 1
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                    i += 1
                    out.append(["type": "codeBlock", "content": code.isEmpty ? [CanvasJSON]() : [["type": "text", "text": code.joined(separator: "\n")] as CanvasJSON]])
                    continue
                }
                if let match = line.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                    let level = line[match].filter { $0 == "#" }.count
                    out.append(["type": "heading", "attrs": ["level": level], "content": inline(String(line[match.upperBound...]))])
                    i += 1; continue
                }
                if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                    out.append(["type": "horizontalRule"]); i += 1; continue
                }
                if line.hasPrefix(">") {
                    var quote: [CanvasJSON] = []
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        quote.append(paragraph(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)))
                        i += 1
                    }
                    out.append(["type": "blockquote", "content": quote]); continue
                }
                if line.hasPrefix("|") {
                    var rows: [[String]] = []
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        let cells = lines[i].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                        if !cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { rows.append(cells) }
                        i += 1
                    }
                    let width = rows.map(\.count).max() ?? 1
                    let table: [CanvasJSON] = rows.enumerated().map { (r, cells) in
                        let padded = cells + Array(repeating: "", count: width - cells.count)
                        return ["type": "tableRow", "content": padded.map { cell -> CanvasJSON in
                            ["type": r == 0 ? "tableHeader" : "tableCell", "content": [paragraph(cell)]] }]
                    }
                    out.append(["type": "table", "content": table]); continue
                }
                if let kind = listKind(line) {
                    var items: [CanvasJSON] = []
                    while i < lines.count, let k = listKind(lines[i].trimmingCharacters(in: .whitespaces)), k == kind {
                        let item = lines[i].trimmingCharacters(in: .whitespaces)
                        switch kind {
                        case .task:
                            let done = item.lowercased().hasPrefix("- [x]") || item.lowercased().hasPrefix("* [x]")
                            items.append(["type": "taskItem", "attrs": ["checked": done], "content": [paragraph(String(item.dropFirst(5)).trimmingCharacters(in: .whitespaces))]])
                        case .bullet:
                            items.append(["type": "listItem", "content": [paragraph(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces))]])
                        case .ordered:
                            let text = item.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
                            items.append(["type": "listItem", "content": [paragraph(text)]])
                        }
                        i += 1
                    }
                    switch kind {
                    case .task: out.append(["type": "taskList", "content": items])
                    case .bullet: out.append(["type": "bulletList", "content": items])
                    case .ordered: out.append(["type": "orderedList", "attrs": ["start": 1], "content": items])
                    }
                    continue
                }
                // A paragraph runs to the next blank line or block.
                var text = [line]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.hasPrefix("#") || next.hasPrefix("```") || next.hasPrefix(">") || next.hasPrefix("|") || listKind(next) != nil { break }
                    text.append(next); i += 1
                }
                out.append(paragraph(text.joined(separator: " ")))
            }
            return out
        }

        enum ListKind { case bullet, ordered, task }
        static func listKind(_ line: String) -> ListKind? {
            if line.range(of: #"^[-*]\s+\[[ xX]\]\s"#, options: .regularExpression) != nil { return .task }
            if line.range(of: #"^[-*]\s+\S"#, options: .regularExpression) != nil { return .bullet }
            if line.range(of: #"^\d+[.)]\s+\S"#, options: .regularExpression) != nil { return .ordered }
            return nil
        }

        /// Text with `**bold**`, `*italic*`, `` `code` `` and `[link](url)` as marked text nodes.
        static func inline(_ text: String) -> [CanvasJSON] {
            var out: [CanvasJSON] = []
            var rest = Substring(text)
            func push(_ s: String, _ marks: [CanvasJSON] = []) {
                guard !s.isEmpty else { return }
                var node: CanvasJSON = ["type": "text", "text": s]
                if !marks.isEmpty { node["marks"] = marks }
                out.append(node)
            }
            let patterns: [(String, (NSTextCheckingResult, String) -> (String, [CanvasJSON])?)] = [
                (#"\[([^\]]+)\]\(([^)\s]+)\)"#, { m, s in
                    let ns = s as NSString
                    let url = ns.substring(with: m.range(at: 2))
                    guard url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("xool-brain://") else { return (ns.substring(with: m.range(at: 1)), []) }
                    return (ns.substring(with: m.range(at: 1)), [["type": "link", "attrs": ["href": url]]])
                }),
                (#"\*\*([^*]+)\*\*"#, { m, s in ((s as NSString).substring(with: m.range(at: 1)), [["type": "bold"]]) }),
                (#"(?<![*\w])[*_]([^*_]+)[*_](?![*\w])"#, { m, s in ((s as NSString).substring(with: m.range(at: 1)), [["type": "italic"]]) }),
                (#"`([^`]+)`"#, { m, s in ((s as NSString).substring(with: m.range(at: 1)), [["type": "code"]]) }),
            ]
            while !rest.isEmpty {
                let s = String(rest)
                var best: (range: NSRange, text: String, marks: [CanvasJSON])?
                for (pattern, build) in patterns {
                    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
                          let made = build(m, s) else { continue }
                    if best == nil || m.range.location < best!.range.location { best = (m.range, made.0, made.1) }
                }
                guard let best else { push(s); break }
                push((s as NSString).substring(to: best.range.location))
                push(best.text, best.marks)
                rest = Substring((s as NSString).substring(from: best.range.location + best.range.length))
            }
            return out
        }
    }
}
