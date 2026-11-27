import SwiftUI

/// An answer in the thread, with its Markdown read: bold and italics, lists, headings, code, and links shown
/// as their title (a bare address as the site's name) that open in the browser. Never a raw `**` or `[…](…)`.
struct ChatText: View {
    let text: String
    /// Jarvis writes without emoji: they are dropped when shown.
    var noEmoji = false

    private enum Block: Equatable {
        case paragraph(String), heading(String), bullet(String, marker: String), quote(String), code(String)
    }

    var body: some View {
        let blocks = Self.blocks(of: noEmoji ? Self.withoutEmoji(Self.titled(text)) : Self.titled(text))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(block) }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let id = BrainStore.id(from: url) { BrainStore.shared.show(id); return .handled }
            if ["http", "https"].contains(url.scheme ?? "") { Browsers.frontBrowser.open(url, foreground: true); return .handled }
            return .systemAction
        })
    }

    @ViewBuilder
    private func view(_ block: Block) -> some View {
        switch block {
        case .paragraph(let line): Text(Self.inline(line))
        case .heading(let line): Text(Self.inline(line)).fontWeight(.semibold)
        case .bullet(let line, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(Theme.textMuted)
                Text(Self.inline(line))
            }
        case .quote(let line):
            Text(Self.inline(line)).foregroundStyle(Theme.textMuted)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
        case .code(let code):
            Text(code).font(.system(size: 12, design: .monospaced))
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
        }
    }

    // MARK: reading

    static func inline(_ line: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return BrainText.styled(parsed)
        }
        return AttributedString(line)
    }

    /// A bare address becomes `[site](address)`, so only a title is shown.
    static func titled(_ text: String) -> String {
        guard text.contains("http") else { return text }
        let pattern = #"(?<![\(\[<"'])https?://[^\s\)\]>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            var address = String(out[range])
            var tail = ""
            while let last = address.last, ".,;:!?".contains(last) { tail = String(last) + tail; address.removeLast() }
            let host = URL(string: address)?.host()?.replacingOccurrences(of: "www.", with: "") ?? address
            out.replaceSubrange(range, with: "[\(host)](\(address))\(tail)")
        }
        return out
    }

    static func withoutEmoji(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let p = scalar.properties
            if (p.isEmojiPresentation || (p.isEmoji && scalar.value > 0x2100)) || scalar.value == 0xFE0F || scalar.value == 0x200D { continue }
            scalars.append(scalar)
        }
        return String(scalars).replacingOccurrences(of: "  ", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .init(charactersIn: " ")).isEmpty ? "" : String($0) }
            .joined(separator: "\n")
    }

    private static func blocks(of text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code { out.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), hashes != trimmed.startIndex, trimmed[hashes] == " ", trimmed.distance(from: trimmed.startIndex, to: hashes) <= 4 {
                flush(); out.append(.heading(String(trimmed[trimmed.index(after: hashes)...]))); continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush(); out.append(.bullet(String(trimmed.dropFirst(2)), marker: "•")); continue
            }
            if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex, trimmed[..<dot].allSatisfy(\.isNumber),
               trimmed.index(after: dot) < trimmed.endIndex, trimmed[trimmed.index(after: dot)] == " " {
                flush(); out.append(.bullet(String(trimmed[trimmed.index(dot, offsetBy: 2)...]), marker: String(trimmed[..<dot]) + ".")); continue
            }
            if trimmed.hasPrefix("> ") { flush(); out.append(.quote(String(trimmed.dropFirst(2)))); continue }
            paragraph.append(line)
        }
        if let open = code { out.append(.code(open.joined(separator: "\n"))) }
        flush()
        return out
    }
}
