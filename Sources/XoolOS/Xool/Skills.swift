import Foundation

/// A skill in the format Claude's skills use: a folder with SKILL.md, whose
/// frontmatter names it (`name`, `description`) and whose text says how.
/// They live in `Application Support/Xool/skills`; an agent keeps a list of
/// them, and `/` in a thread calls one.
struct Skill: Identifiable, Equatable {
    var name: String
    var description: String
    var body: String
    var id: String { name }

    /// `---` frontmatter `---` and the text after it. A file with no
    /// frontmatter is a skill named after its folder (or file) with the first
    /// line as its description.
    static func parse(_ raw: String, fallbackName: String) -> Skill? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n"), let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let header = String(text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound])
            body = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var key: String?
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
                        v = String(v.dropFirst().dropLast())
                    }
                    if v == ">" || v == "|" || v == ">-" || v == "|-" { v = "" }
                    fields[k] = v
                    key = k
                } else if let key, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let more = line.trimmingCharacters(in: .whitespaces)
                    fields[key] = ((fields[key] ?? "") + " " + more).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let name = Self.slug(fields["name"] ?? fallbackName)
        guard !name.isEmpty else { return nil }
        let description = fields["description"] ?? body.split(separator: "\n").first.map(String.init) ?? ""
        return Skill(name: name, description: String(description.prefix(300)), body: body)
    }

    /// The name as it is typed after `/`: lower case, no spaces.
    static func slug(_ text: String) -> String {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = lower.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }
}

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [Skill] = []
    let folder: URL

    init(folder: URL = Store.folder.appendingPathComponent("skills", isDirectory: true)) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    /// `skills/<name>/SKILL.md`, and a loose `skills/<name>.md` as well.
    func reload() {
        let manager = FileManager.default
        var found: [Skill] = []
        for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let file = isFolder ? item.appendingPathComponent("SKILL.md") : item
            guard file.pathExtension.lowercased() == "md",
                  let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fallback = isFolder ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
            if let skill = Skill.parse(raw, fallbackName: fallback), !found.contains(where: { $0.name == skill.name }) {
                found.append(skill)
            }
        }
        skills = found.sorted { $0.name < $1.name }
    }

    func skill(named name: String) -> Skill? {
        let wanted = Skill.slug(name)
        return skills.first { $0.name == wanted }
    }

    /// The skills an agent keeps, as far as they are still on disk.
    func skills(for agent: Agent) -> [Skill] {
        (agent.skills ?? []).compactMap { skill(named: $0) }
    }

    /// A new skill with a few lines to start from.
    @discardableResult
    func create(name: String, description: String) -> Skill? {
        let slug = Skill.slug(name)
        guard !slug.isEmpty else { return nil }
        let dir = folder.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = "---\nname: \(slug)\ndescription: \(description)\n---\n\nSay here, step by step, how to do this.\n"
        try? text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        reload()
        return skill(named: slug)
    }

    /// A message that starts with `/name`: the skill and what follows it.
    static func invocation(in text: String, among skills: [Skill]) -> (skill: Skill, rest: String)? {
        guard text.hasPrefix("/") else { return nil }
        let head = text.dropFirst().prefix { !$0.isWhitespace }
        guard let skill = skills.first(where: { $0.name == Skill.slug(String(head)) }) else { return nil }
        let rest = text.dropFirst(1 + head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (skill, rest)
    }
}
