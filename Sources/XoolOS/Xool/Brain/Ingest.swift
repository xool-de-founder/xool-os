import AppKit
import Foundation
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

/// Reading a file's words: text and code as they are, PDFs through PDFKit
/// (and OCR when they are scans), pictures through Vision, Office files from
/// their XML, anything else from its Quick Look picture. Off the main thread.
enum Ingest {
    struct Read {
        var text: String
        /// How the words were got: "text", "PDF", "OCR", "Office", "preview".
        var how: String
    }

    static let maxText = 400_000

    static func extract(_ url: URL) async -> Read {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        func has(_ parent: UTType) -> Bool { type?.conforms(to: parent) ?? false }

        if ext == "pdf" || has(.pdf) { return pdf(url) }
        if has(.image) { return Read(text: await ocr(url: url), how: "OCR") }
        if ["docx", "xlsx", "pptx", "odt", "ods", "odp"].contains(ext) {
            let words = ooxml(url)
            if !words.isEmpty { return Read(text: words, how: "Office") }
        }
        if ["rtf", "rtfd", "doc", "docx", "odt", "webarchive"].contains(ext),
           let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            let words = attributed.string
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Read(text: clip(words), how: "Office") }
        }
        if ["html", "htm", "xhtml"].contains(ext), let raw = readText(url) {
            return Read(text: clip(stripTags(raw)), how: "text")
        }
        if isText(url, type: type), let raw = readText(url) { return Read(text: clip(raw), how: "text") }
        // Anything else (Pages, Keynote, Numbers, …): what its preview shows.
        if let image = await previewImage(url, side: 1800), let words = ocr(cgImage: image), !words.isEmpty {
            return Read(text: words, how: "preview")
        }
        return Read(text: "", how: "none")
    }

    // MARK: text

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "ini", "xml", "log", "tex", "rst",
        "swift", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "rb", "php", "sh", "zsh",
        "sql", "css", "scss", "lua", "r", "pl", "cs", "dart", "vue", "svelte", "conf", "env", "gitignore", "srt", "vtt",
    ]

    private static func isText(_ url: URL, type: UTType?) -> Bool {
        if textExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) { return true }
        // No extension and no type: a file whose first bytes read as text.
        guard url.pathExtension.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)) ?? Data()
        return !head.isEmpty && !head.contains(0) && String(data: head, encoding: .utf8) != nil
    }

    private static func readText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_000_000), !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func clip(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxText ? String(trimmed.prefix(maxText)) : trimmed
    }

    private static func stripTags(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    // MARK: PDF

    private static func pdf(_ url: URL) -> Read {
        guard let document = PDFDocument(url: url) else { return Read(text: "", how: "none") }
        let text = clip(document.string ?? "")
        // A scan has no text layer: read its first pages as pictures.
        if text.count >= 40 || document.pageCount == 0 { return Read(text: text, how: "PDF") }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 25) {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = 1800 / max(box.width, box.height, 1)
            let image = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let words = ocr(cgImage: cg), !words.isEmpty {
                pages.append(words)
            }
        }
        return Read(text: clip(pages.joined(separator: "\n\n")), how: "OCR")
    }

    // MARK: pictures

    static func ocr(url: URL) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return ocr(cgImage: image) ?? ""
    }

    static func ocr(cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: Office

    /// docx, xlsx, pptx and the Open Document files are zips of XML: the
    /// words are in a few known parts, read with the system's own unzip.
    private static func ooxml(_ url: URL) -> String {
        let parts = ["word/document.xml", "xl/sharedStrings.xml", "ppt/slides/slide*.xml", "content.xml"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + parts
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        // Read to the end before waiting, or a big pipe stalls the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var xml = String(decoding: data.prefix(24_000_000), as: UTF8.self)
        xml = xml.replacingOccurrences(of: "</w:p>|</a:p>|</text:p>|</si>|</row>", with: "\n", options: .regularExpression)
        return clip(stripTags(xml))
    }

    // MARK: previews

    static func previewImage(_ url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// A small picture of the file, as a PNG at `destination`.
    static func thumbnail(_ url: URL, to destination: URL) async -> Bool {
        guard let image = await previewImage(url, side: 640) else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: destination)) != nil
    }

    /// A text cut into pieces of about `size` characters at paragraph or
    /// sentence ends, for vectors. The title leads the first, so a title's
    /// words count for meaning too.
    static func chunks(title: String, text: String, size: Int = 700, most: Int = 24) -> [String] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return title.isEmpty ? [] : [title] }
        var out: [String] = []
        var current = title.isEmpty ? "" : title + "\n"
        let paragraphs = body.replacingOccurrences(of: "\n{2,}", with: "\n\n", options: .regularExpression).components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            var rest = Substring(paragraph)
            while !rest.isEmpty {
                let room = max(size - current.count, 0)
                if rest.count <= room || (current.isEmpty && rest.count <= size) {
                    current += (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + rest
                    rest = ""
                } else if room > 120 {
                    let cut = sentenceEnd(in: rest, near: room)
                    current += (current.hasSuffix("\n") || current.isEmpty ? "" : " ") + rest[..<cut]
                    rest = rest[cut...].drop { $0.isWhitespace }
                    out.append(current); current = ""
                } else {
                    if !current.isEmpty { out.append(current); current = "" }
                    else {
                        let cut = sentenceEnd(in: rest, near: size)
                        out.append(String(rest[..<cut]))
                        rest = rest[cut...].drop { $0.isWhitespace }
                    }
                }
                if out.count >= most { return out }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return Array(out.prefix(most))
    }

    private static func sentenceEnd(in text: Substring, near limit: Int) -> Substring.Index {
        let hard = text.index(text.startIndex, offsetBy: min(limit, text.count))
        let window = text[text.startIndex..<hard]
        if let stop = window.lastIndex(where: { ".!?。\n".contains($0) }), window.distance(from: window.startIndex, to: stop) > limit / 2 {
            return text.index(after: stop)
        }
        if let space = window.lastIndex(of: " "), window.distance(from: window.startIndex, to: space) > limit / 2 { return space }
        return hard
    }
}
