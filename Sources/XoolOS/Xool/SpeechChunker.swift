import Foundation

/// Cuts a streamed answer into pieces a voice can start on. The first piece
/// may end at a comma once it has a few words, so the voice starts early;
/// later pieces end at sentence ends. From jarvis-on-nod's SentenceChunker.
struct SpeechChunker {
    var firstMinWords = 4
    var firstMaxChars = 90
    var maxChars = 220
    private var buffer = ""
    private var emitted = 0
    private var inThink = false

    private static let abbreviations: Set<String> = [
        "z.b", "u.a", "d.h", "bzw", "ca", "dr", "prof", "nr", "str", "usw", "evtl", "ggf", "inkl", "vgl", "etc",
        "mio", "mrd", "min", "max", "std", "sek", "bsp", "z.t", "o.ä", "u.ä", "co", "tel", "abs", "art", "mr", "mrs",
        "e.g", "i.e", "vs", "st", "no",
    ]

    mutating func feed(_ text: String) -> [String] {
        buffer += stripThink(text)
        // A finished link is just its words from here on.
        buffer = buffer.replacingOccurrences(of: #"\[([^\]]+)\]\([^)\s]*\)"#, with: "$1", options: .regularExpression)
        var ready: [String] = []
        while let piece = take() { ready.append(piece) }
        return ready
    }

    mutating func flush() -> [String] {
        if !inThink { buffer += tagCarry }
        tagCarry = ""
        let rest = Self.clean(buffer)
        buffer = ""
        if rest.isEmpty { return [] }
        emitted += 1
        return [rest]
    }

    // MARK: pieces

    /// A tag cut in two by the stream ("<thi" + "nk>") waits here for its other half.
    private var tagCarry = ""

    private static func partialSuffix(of text: String, for tag: String) -> String {
        for length in stride(from: min(tag.count - 1, text.count), through: 1, by: -1) where text.hasSuffix(String(tag.prefix(length))) {
            return String(tag.prefix(length))
        }
        return ""
    }

    private mutating func stripThink(_ token: String) -> String {
        var out = "", rest = Substring(tagCarry + token)
        tagCarry = ""
        while !rest.isEmpty {
            if inThink {
                guard let end = rest.range(of: "</think>") else {
                    tagCarry = Self.partialSuffix(of: String(rest), for: "</think>")
                    return out
                }
                rest = rest[end.upperBound...]
                inThink = false
            } else if let start = rest.range(of: "<think>") {
                out += rest[..<start.lowerBound]
                rest = rest[start.upperBound...]
                inThink = true
            } else {
                let partial = Self.partialSuffix(of: String(rest), for: "<think>")
                tagCarry = partial
                out += rest.dropLast(partial.count)
                break
            }
        }
        return out
    }

    /// Where a piece must end at the latest: before a link or address that
    /// is still arriving (cut in the middle it would be read out as junk).
    private static func openEnd(_ chars: [Character]) -> Int {
        let text = String(chars)
        var limit = chars.count
        if let open = text.range(of: #"\[[^\]]*$"#, options: .regularExpression) ?? text.range(of: #"\[[^\]]+\]\([^)]*$"#, options: .regularExpression) {
            limit = min(limit, text.distance(from: text.startIndex, to: open.lowerBound))
        }
        if let url = text.range(of: #"https?://\S*$"#, options: .regularExpression) {
            limit = min(limit, text.distance(from: text.startIndex, to: url.lowerBound))
        }
        return limit
    }

    /// The part of the buffer after an unfinished link, kept for later.
    private var held: [Character] = []

    private mutating func take() -> String? {
        let all = Array(buffer)
        let limit = Self.openEnd(all)
        let chars = Array(all[..<limit])
        held = Array(all[limit...])
        // A sentence end: . ! ? … then a space or newline.
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if ".!?…".contains(c) {
                var end = i
                while end + 1 < chars.count, ".!?…".contains(chars[end + 1]) || "\"»“”')]".contains(chars[end + 1]) { end += 1 }
                if end + 1 < chars.count, chars[end + 1].isWhitespace, Self.realEnd(chars, at: i) {
                    return cut(chars, end + 1) ?? take()
                }
                i = end
            }
            i += 1
        }
        if emitted == 0 {
            for (index, c) in chars.enumerated() where ",;:–—".contains(c) && index + 1 < chars.count && chars[index + 1].isWhitespace {
                if String(chars[..<index]).split(whereSeparator: \.isWhitespace).count >= firstMinWords {
                    return cut(chars, index + 1) ?? take()
                }
            }
            if chars.count > firstMaxChars, let space = chars[..<firstMaxChars].lastIndex(of: " ") {
                return cut(chars, space + 1) ?? take()
            }
        }
        if chars.count > maxChars, let space = chars[..<maxChars].lastIndex(of: " ") {
            return cut(chars, space + 1) ?? take()
        }
        return nil
    }

    private mutating func cut(_ chars: [Character], _ end: Int) -> String? {
        let piece = Self.clean(String(chars[..<end]))
        buffer = String(chars[end...]) + String(held)
        if piece.isEmpty { return nil }
        emitted += 1
        return piece
    }

    /// False for "z.B.", "Dr.", "3." and an initial.
    private static func realEnd(_ chars: [Character], at dot: Int) -> Bool {
        guard chars[dot] == "." else { return true }
        let before = String(chars[..<dot])
        guard let word = before.split(whereSeparator: \.isWhitespace).last.map({ $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'„»")) }),
              !word.isEmpty else { return true }
        if abbreviations.contains(word) { return false }
        if word.allSatisfy(\.isNumber) { return false }
        if word.count == 1, word.first?.isLetter == true { return false }
        return true
    }

    // MARK: cleaning

    /// What a voice shouldn't read: markdown, links, emoji, lists.
    static func clean(_ raw: String) -> String {
        var text = raw
        let rules: [(String, String)] = [
            (#"[\[(]\s*https?://[^\])\s]*\s*[\])]"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"https?://\S+"#, ""),
            (#"`{1,3}"#, ""),
            (#"(\*\*|__|\*|~~)"#, ""),
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),
            (#"(?m)^\s*[-•*+]\s+"#, ""),
            (#"(?m)^\s*\d+[.)]\s+"#, ""),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = String(text.unicodeScalars.filter { !($0.properties.isEmojiPresentation || (0x1F000...0x1FAFF).contains($0.value)) })
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
