import AppIntents

// "Talk to Jarvis" for Shortcuts and Spotlight (docs/PLAN.md 8, G): it
// starts the voice listening to Jarvis, as the global key and the menu-bar
// icon do. Put it on the Action button, call it with Siri, or give it a key
// in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts. build.sh
// extracts the metadata that makes Shortcuts find it (Metadata.appintents).

struct TalkToJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Jarvis"
    static let description = IntentDescription("Starts listening to you. Jarvis answers aloud and in his thread.")
    /// The voice needs the app running; it comes up without taking the front.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceBridge.shared.listenToJarvis()
        return .result()
    }
}

struct XoolShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToJarvisIntent(),
                    phrases: ["Talk to Jarvis in \(.applicationName)",
                              "Mit Jarvis sprechen in \(.applicationName)",
                              "Ask Jarvis in \(.applicationName)"],
                    shortTitle: "Talk to Jarvis",
                    systemImageName: "waveform")
    }
}
