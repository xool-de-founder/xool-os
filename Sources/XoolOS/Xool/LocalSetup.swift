import Foundation
import SwiftUI

/// "Set up local AI": runs scripts/xool-setup.sh and shows how far it got.
/// The script does the work (Ollama, model, 64k context, voice); this reads
/// its output: "▶ Step n/6: …" lines are the steps, "✘" lines the trouble,
/// and the line after a ✘ that starts with "Next:" says what to do.
@MainActor
final class LocalSetup: ObservableObject {
    static let shared = LocalSetup()

    enum Phase: Equatable {
        case idle
        case running
        case done(problems: Bool)
        case failed(what: String, next: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step = 0
    @Published private(set) var steps = 6
    @Published private(set) var title = ""
    /// 0…1 of a download, when the last line says a percentage.
    @Published private(set) var download: Double?
    @Published private(set) var lines: [String] = []

    private var process: Process?
    private var carry = Data()
    private var lastBad: String?
    private var cancelled = false

    var running: Bool { phase == .running }

    /// The script: in the app bundle, or in a checkout (`swift run`).
    static var script: URL? {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("xool-setup.sh")]
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/xool-setup.sh"))
        return candidates.compactMap { $0 }.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    func start(check: Bool = false, onlyVoice: Bool = false) {
        guard !running else { return }
        guard let script = Self.script else {
            phase = .failed(what: "The setup script isn't in this build.",
                            next: "Run it in Terminal: curl -fsSL https://raw.githubusercontent.com/xool-de-founder/xool-os/main/scripts/xool-setup.sh | bash")
            return
        }
        lines = []; step = 0; steps = onlyVoice ? 2 : 6; title = "Starting"; download = nil; lastBad = nil; cancelled = false; carry = Data()
        phase = .running
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--yes"] + (check ? ["--check"] : []) + (onlyVoice ? ["--only-voice"] : [])
        var env = ProcessInfo.processInfo.environment
        // An app starts with a short PATH: Ollama and uv live elsewhere.
        env["PATH"] = ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        env["XOOL_YES"] = "1"
        if let voice = SidecarEngine.source { env["XOOL_VOICE_SRC"] = voice.path }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.take(data) }
        }
        process.terminationHandler = { [weak self] done in
            Task { @MainActor in self?.finished(done.terminationStatus) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            phase = .failed(what: "The setup couldn't start: \(error.localizedDescription)", next: "Run it in Terminal instead (see the README).")
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func dismiss() { if !running { phase = .idle; lines = [] } }

    // MARK: reading the script

    private func take(_ data: Data) {
        carry.append(data)
        while let end = carry.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = carry[..<end]
            carry = Data(carry[(end + 1)...])
            if let text = String(data: line, encoding: .utf8) { read(Self.plain(text)) }
        }
    }

    /// Without the colour codes.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func read(_ line: String) {
        guard !line.isEmpty, !line.hasPrefix("──") else { return }
        if let found = line.range(of: #"Step (\d+)/(\d+): (.*)"#, options: .regularExpression), line.hasPrefix("▶") {
            let parts = line[found].dropFirst(5).split(separator: ":", maxSplits: 1)
            let numbers = parts[0].split(separator: "/").compactMap { Int($0) }
            if numbers.count == 2 { step = numbers[0]; steps = numbers[1] }
            title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : title
            download = nil
            append(line)
            return
        }
        if let percent = line.range(of: #"(\d{1,3})%"#, options: .regularExpression), line.lowercased().contains("pull") || line.contains("▕") {
            download = (Double(line[percent].dropLast()) ?? 0) / 100
            // A download redraws its line again and again: keep only the newest.
            if let last = lines.last, last.contains("%"), last.lowercased().contains("pull") || last.contains("▕") { lines.removeLast() }
        }
        if line.hasPrefix("✘") { lastBad = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("Next:") { nextStep = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        append(line)
    }

    private var nextStep: String?

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
    }

    private func finished(_ code: Int32) {
        process = nil
        download = nil
        if cancelled { phase = .failed(what: "Stopped.", next: "Start it again any time. It continues where it left off."); return }
        switch code {
        case 0, 3:
            phase = .done(problems: code == 3)
            VoiceBridge.shared.restart()
            Task { await OllamaCatalog.shared.refresh(); await ModelStore.shared.refresh() }
        default:
            phase = .failed(what: lastBad ?? "The setup stopped.", next: nextStep ?? "Run it again, or look at the log below.")
        }
        nextStep = nil
    }
}

/// The card in Settings › Models: a button, then the steps as they go.
struct LocalSetupCard: View {
    @ObservedObject private var setup = LocalSetup.shared
    @ObservedObject private var voice = VoiceBridge.shared
    @XState private var showLog = false

    var body: some View {
        Card {
            switch setup.phase {
            case .idle:
                Line("Set up local AI",
                     "Installs Ollama if it's missing, pulls a model that fits this Mac, gives it a 64k context and sets up the voice. Deletes nothing, asks for no password") {
                    HStack(spacing: 6) {
                        Pill("Check") { setup.start(check: true) }
                        Pill("Set up local AI", filled: true) { setup.start() }
                    }
                }
            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Step \(max(setup.step, 1)) of \(setup.steps) · \(setup.title)")
                            .font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Pill("Stop") { setup.cancel() }
                    }
                    ProgressView(value: setup.download ?? (Double(max(setup.step - 1, 0)) / Double(max(setup.steps, 1))))
                        .progressViewStyle(.linear)
                    if let last = setup.lines.last {
                        Text(last).font(Theme.small).foregroundStyle(Theme.textMuted).lineLimit(2)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Setting up. Step \(setup.step) of \(setup.steps), \(setup.title)")
            case .done(let problems):
                Line(problems ? "Almost there" : "Local AI is ready",
                     problems ? "Something needs a look. See the log" : "Ollama, the model and the voice are set up. Hold fn to talk to an agent") {
                    HStack(spacing: 6) {
                        Pill("Log") { showLog.toggle() }
                        Pill("Done", filled: true) { setup.dismiss() }
                    }
                }
            case .failed(let what, let next):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Label(what, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        Pill("Log") { showLog.toggle() }
                        Pill("Try again", filled: true) { setup.start() }
                    }
                    Text("Next: \(next)").font(Theme.small).foregroundStyle(Theme.textMuted).textSelection(.enabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
            if showLog, !setup.lines.isEmpty {
                Rule()
                ScrollView {
                    Text(setup.lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 150)
            }
        }
    }
}

/// The voice: which key talks, whether you can talk over it, and whether the
/// better voice is installed.
struct VoiceSettingsCard: View {
    @ObservedObject private var voice = VoiceBridge.shared
    @ObservedObject private var setup = LocalSetup.shared
    @ObservedObject private var entry = JarvisEntry.shared

    var body: some View {
        Card {
            Line("Push to talk", "Hold the key and speak to the agent you used last. Let go when you're done") {
                Segmented(options: [("fn", "fn"), ("optionSpace", "⌥ Space")], selection: $voice.key)
            }
            Rule()
            Line("Talk to Jarvis from any app", "Hold the key and speak; press it briefly to listen until you press it again. Works while Xool OS is in the background") {
                JarvisKeyBox()
            }
            Rule()
            Line("Menu bar icon", "Click it to talk to Jarvis, right-click for recent threads") {
                Switch(on: $entry.menuBar)
            }
            Rule()
            Line("Conversation", "⌥⌘J pressed briefly, or the waveform in Jarvis' office: the microphone stays open and you needn't press a key per sentence") {
                Pill(voice.conversing ? "End" : "Start", filled: !voice.conversing) { VoiceBridge.shared.toggleConversation() }
            }
            Rule()
            Line("Follow-ups without his name", "After “Jarvis …” or an answer he keeps listening this long. Sentences that aren't for him are ignored") {
                Segmented(options: [("10", "10 s"), ("20", "20 s"), ("40", "40 s")], selection: Binding(
                    get: { String(Int(voice.sessionSeconds)) }, set: { voice.sessionSeconds = Double($0) ?? 20 }))
            }
            Rule()
            Line("Pause that ends your sentence", "How long you can be quiet before he answers. Shorter is quicker, longer lets you think aloud") {
                Segmented(options: [("0.35", "0.35 s"), ("0.5", "0.5 s"), ("0.8", "0.8 s")], selection: Binding(
                    get: { String(format: "%g", voice.pauseSeconds) }, set: { voice.pauseSeconds = Double($0) ?? 0.5 }))
            }
            Rule()
            Line("Say “Hey Jarvis”", "Wakes him without a key (openWakeWord, on this Mac). Needs the better voice") {
                Switch(on: $voice.wakeWord)
            }
            Rule()
            Line("Talk over the voice", "Start talking and the voice stops at once. Turn off if it hears itself through the speakers; headphones always work") {
                Switch(on: $voice.bargeIn)
            }
            Rule()
            Line(SidecarEngine.installed ? "Voice: Whisper and Piper" : "Voice: Apple speech",
                 SidecarEngine.installed ? "Listens and speaks on this Mac, with hands-free and bridge phrases"
                                         : "Works now, push to talk only. Set up local AI above for the better voice, hands-free included") {
                if !SidecarEngine.installed {
                    Pill("Set up", filled: true) { setup.start() }
                        .disabled(setup.running)
                }
            }
            Rule()
            Line("Other apps in front", "To talk while another app is open, allow Xool OS under Privacy & Security › Input Monitoring") {
                Pill("Allow") {
                    if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
