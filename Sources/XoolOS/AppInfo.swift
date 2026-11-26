import Foundation
import Security

/// What this app is: the version people read and the build number.
enum AppInfo {
    nonisolated static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    nonisolated static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// The team whose Developer ID signs the optional "On this Mac" engine.
    /// Xool OS ships no engine feed, so nothing is offered or started until
    /// one is configured; the check stays as strict as it was.
    nonisolated static let engineTeam = "7BYKA895MC"

    nonisolated static func developerID(team: String, identifier: String?) -> SecRequirement? {
        let text = "anchor apple generic" + (identifier.map { " and identifier \"\($0)\"" } ?? "")
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
