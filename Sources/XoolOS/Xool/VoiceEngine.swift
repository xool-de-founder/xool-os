import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// What the sidecar made of a sentence it heard, before any model read it.
struct Heard: Equatable {
    /// The situation, for a bridge phrase ("frage", "websuche", …).
    var kind = ""
    /// "wissen", "web", "browser", "brain", "delegate" or "calc" (empty: not judged).
    var route = ""
    var tools = false
    /// The assistant's name was said.
    var named = false
    /// Milliseconds Whisper took.
    var ms = 0
}

/// What an engine tells the bridge.
enum VoiceEvent {
    case ready(String)
    case loading(String)
    /// You started talking (the key went down, or the VAD heard you).
    case speechStart
    /// You talked over the voice: it is already silent.
    case bargeIn
    /// What you said; `kind` is the situation ("frage", "befehl", …) for a bridge phrase.
    case transcript(String, Heard)
    /// What you have said so far in the sentence that is still going (live text).
    case partial(String)
    case speaking(Bool)
    /// Nothing is being said any more.
    case idle
    case bridge(String)
    /// The ears are loaded and the models warm: the next sentence is understood at once.
    case warm
    /// "Hey Jarvis" was heard (openWakeWord).
    case wake
    case error(String, mic: Bool, fatal: Bool)
}

enum ListenMode: String { case off, ptt, vad }

/// Ears and mouth. The thinking is the agent's; an engine only hears and speaks.
@MainActor
protocol VoiceEngine: AnyObject {
    var name: String { get }
    /// Hands-free listening (with barge-in) is possible.
    var handsFree: Bool { get }
    var onEvent: ((VoiceEvent) -> Void)? { get set }
    func start() throws
    func shutdown()
    func listen(_ mode: ListenMode, bargeIn: Bool)
    func ptt(down: Bool)
    func say(_ text: String, first: Bool)
    func bridge(_ kind: String)
    /// Listen for "Hey Jarvis" (sidecar only; others ignore it).
    func wake(_ on: Bool)
    func stop()
    /// Test input: a WAV file in place of the microphone.
    func transcribe(file: URL)
}

// MARK: - the sidecar

/// `python -m xool_voice --serve` from the app bundle, in the venv that
/// scripts/xool-setup.sh made. JSON lines both ways (see server.py).
@MainActor
final class SidecarEngine: VoiceEngine {
    let name = "Whisper + Piper"
    let handsFree = true
    var onEvent: ((VoiceEvent) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var carry = Data()

    static var home: URL {
        if let set = getenv("XOOL_VOICE_HOME") { return URL(fileURLWithPath: String(cString: set)) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xool/voice", isDirectory: true)
    }
    static var python: URL { home.appendingPathComponent("venv/bin/python") }

    /// The sidecar's code: in the app bundle, or beside a checkout when run with `swift run`.
    static var source: URL? {
        if let set = getenv("XOOL_VOICE_SRC") { return URL(fileURLWithPath: String(cString: set)) }
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("voice")]
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/voice"))
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("xool_voice/__main__.py").path) }
    }

    /// Set up: the venv, the code and a voice file.
    static var installed: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: python.path), source != nil else { return false }
        let voices = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent("voices").path)) ?? []
        return voices.contains { $0.hasSuffix(".onnx") }
    }

    func start() throws {
        guard let source = Self.source, Self.installed else { throw VoiceError.notInstalled }
        let process = Process()
        process.executableURL = Self.python
        var args = ["-m", "xool_voice", "--serve", "--language", VoiceBridge.language.split(separator: "-").first.map(String.init) ?? "de",
                    "--name", AgentStore.shared.jarvis.name, "--pause", String(VoiceBridge.pause)]
        if getenv("XOOL_VOICE_NULL") != nil { args.append("--null-audio") }
        // Tests: a recording of what would be said, and a recorded WAV as the microphone.
        if getenv("XOOL_VOICE_RECORD") != nil { args.append("--record") }
        if getenv("XOOL_VOICE_FAKEMIC") != nil { args += ["--fake-mic", "--echo-gain", "0.15"] }
        process.arguments = args
        process.currentDirectoryURL = source
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = source.path
        env["PYTHONUNBUFFERED"] = "1"
        env["XOOL_VOICE_HOME"] = Self.home.path
        env["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.take(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            if Store.testing { FileHandle.standardError.write(Data(("voice: " + text).utf8)) }
            for line in text.split(separator: "\n") where !line.isEmpty { VoiceBridge.log("sidecar: \(line)") }
        }
        process.terminationHandler = { [weak self] done in
            Task { @MainActor in
                guard let self, self.process === done else { return }
                self.process = nil
                self.input = nil
                VoiceBridge.log("the sidecar ended with code \(done.terminationStatus)")
                self.onEvent?(.error("The voice stopped (code \(done.terminationStatus)). Press the key again to restart it.", mic: false, fatal: true))
            }
        }
        VoiceBridge.log("starting the sidecar: \(Self.python.path) \(args.joined(separator: " "))")
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    func shutdown() {
        send(["cmd": "quit"])
        let old = process
        process = nil
        input = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if old?.isRunning == true { old?.terminate() } }
    }

    private func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        try? input.write(contentsOf: data)
    }

    private func take(_ data: Data) {
        carry.append(data)
        while let newline = carry.firstIndex(of: 10) {
            let line = carry[..<newline]
            carry = Data(carry[(newline + 1)...])
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let ev = json["ev"] as? String else { continue }
            switch ev {
            case "ready":
                VoiceBridge.log("sidecar ready: voice \(json["tts"] as? String ?? "?"), speaker \(json["output"] as? String ?? "?"), microphone \(json["input"] as? String ?? "?")")
                onEvent?(.ready(json["tts"] as? String ?? ""))
            case "partial": onEvent?(.partial(json["text"] as? String ?? ""))
            case "loading": onEvent?(.loading(json["what"] as? String ?? ""))
            case "speech_start": onEvent?(.speechStart)
            case "transcript":
                onEvent?(.transcript(json["text"] as? String ?? "", Heard(
                    kind: json["kind"] as? String ?? "", route: json["route"] as? String ?? "",
                    tools: json["tools"] as? Bool ?? false, named: json["named"] as? Bool ?? false,
                    ms: (json["ms_stt"] as? NSNumber)?.intValue ?? 0)))
            case "warm": onEvent?(.warm)
            case "wake": onEvent?(.wake)
            case "speaking": onEvent?(.speaking(json["on"] as? Bool ?? false))
            case "idle": onEvent?(.idle)
            case "bridge": onEvent?(.bridge(json["text"] as? String ?? ""))
            case "sound", "barge_in", "bridges", "saved":
                if Store.testing { FileHandle.standardError.write(Data("voice \(ev): \(json)\n".utf8)) }
                VoiceBridge.log("sidecar \(ev) \(json)")
                if ev == "barge_in" { onEvent?(.bargeIn) }
            case "error": onEvent?(.error(json["text"] as? String ?? "Voice error", mic: json["mic"] as? Bool ?? false, fatal: json["fatal"] as? Bool ?? false))
            default: break
            }
        }
    }

    func listen(_ mode: ListenMode, bargeIn: Bool) { send(["cmd": "listen", "mode": mode.rawValue, "barge_in": bargeIn, "pause": VoiceBridge.pause]) }
    func wake(_ on: Bool) { send(["cmd": "wake", "on": on]) }
    /// Tests: a WAV the fake microphone hears after `delay` seconds.
    func feedMic(_ path: String, delay: Double) { send(["cmd": "feed", "path": path, "delay": delay]) }
    /// Tests: what would have come out of the speakers, as a WAV.
    func saveOutput(to path: String) { send(["cmd": "save_out", "path": path]) }
    func ptt(down: Bool) { send(["cmd": "ptt", "down": down]) }
    func say(_ text: String, first: Bool) { send(["cmd": "say", "text": text, "first": first]) }
    func bridge(_ kind: String) { send(["cmd": "bridge", "kind": kind]) }
    func stop() { send(["cmd": "stop"]) }
    func transcribe(file: URL) { send(["cmd": "transcribe", "path": file.path]) }
}

enum VoiceError: LocalizedError {
    case notInstalled
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "The voice isn't set up yet."
        }
    }
}

// MARK: - the Mac's own

/// Without the sidecar: the system's speech recognition and voices. Push to
/// talk only; no bridge phrases. Works without setup, in any language the
/// Mac has a voice for.
@MainActor
final class NativeEngine: NSObject, VoiceEngine, AVSpeechSynthesizerDelegate {
    let name = "Apple speech"
    let handsFree = false
    var onEvent: ((VoiceEvent) -> Void)?
    private let synth = AVSpeechSynthesizer()
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var pending = 0
    private var finishing: DispatchWorkItem?

    func start() throws {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: VoiceBridge.language))
        synth.delegate = self
        onEvent?(.ready("Apple"))
    }

    func shutdown() { stop(); endCapture() }

    func listen(_ mode: ListenMode, bargeIn: Bool) {}

    func ptt(down: Bool) {
        if down {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard status == .authorized else {
                        self.onEvent?(.error("Allow speech recognition for Xool OS in System Settings › Privacy & Security › Speech Recognition.", mic: true, fatal: false))
                        self.onEvent?(.transcript("", Heard()))
                        return
                    }
                    self.beginCapture()
                }
            }
        } else {
            // The key goes up a moment after the last word.
            let work = DispatchWorkItem { [weak self] in self?.finishCapture() }
            finishing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func beginCapture() {
        guard task == nil, let recognizer, recognizer.isAvailable else {
            onEvent?(.error("Speech recognition isn't available for this language.", mic: false, fatal: false))
            onEvent?(.transcript("", Heard()))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onEvent?(.error("The microphone isn't available.", mic: true, fatal: false))
            onEvent?(.transcript("", Heard()))
            self.request = nil
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        audio.prepare()
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            onEvent?(.error("The microphone couldn't start: \(error.localizedDescription)", mic: true, fatal: false))
            onEvent?(.transcript("", Heard()))
            return
        }
        onEvent?(.speechStart)
        var delivered = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !delivered else { return }
                if let result, result.isFinal {
                    delivered = true
                    self.task = nil
                    self.onEvent?(.transcript(result.bestTranscription.formattedString, Heard()))
                } else if error != nil {
                    delivered = true
                    self.task = nil
                    self.onEvent?(.transcript("", Heard()))
                }
            }
        }
    }

    private func finishCapture() {
        guard request != nil else { return }
        endCapture()
        // Nothing final within a few seconds: give up quietly.
        let current = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let current, self.task === current else { return }
            current.cancel()
            self.task = nil
            self.onEvent?(.transcript("", Heard()))
        }
    }

    private func endCapture() {
        finishing?.cancel()
        if audio.isRunning { audio.stop(); audio.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        request = nil
    }

    func say(_ text: String, first: Bool) {
        let utterance = AVSpeechUtterance(string: text)
        // The voice follows the sentence's language.
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? VoiceBridge.language
        let locale = language.contains("-") ? language : Self.locale(for: language)
        utterance.voice = Self.bestVoice(locale) ?? AVSpeechSynthesisVoice(language: locale) ?? AVSpeechSynthesisVoice(language: VoiceBridge.language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        pending += 1
        synth.speak(utterance)
    }

    /// The best voice installed for the language: premium, then enhanced, then the plain one.
    static func bestVoice(_ locale: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(locale.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let exact = all.filter { $0.language == locale }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int { v.quality == .premium ? 3 : v.quality == .enhanced ? 2 : 1 }
        return (exact.isEmpty ? all : exact).max { rank($0) < rank($1) }
    }

    private static func locale(for language: String) -> String {
        Locale.preferredLanguages.first { $0.hasPrefix(language) }
            ?? ["de": "de-DE", "en": "en-US", "fr": "fr-FR", "es": "es-ES", "it": "it-IT"][language] ?? language
    }

    func bridge(_ kind: String) {}
    func wake(_ on: Bool) {}

    func stop() {
        pending = 0
        synth.stopSpeaking(at: .immediate)
    }

    func transcribe(file: URL) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: VoiceBridge.language)) else { return }
        let request = SFSpeechURLRecognitionRequest(url: file)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result, result.isFinal { self.task = nil; self.onEvent?(.transcript(result.bestTranscription.formattedString, Heard())) }
                else if error != nil { self.task = nil; self.onEvent?(.transcript("", Heard())) }
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(.speaking(true)) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = max(0, self.pending - 1)
            if self.pending == 0 { self.onEvent?(.speaking(false)); self.onEvent?(.idle) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.synth.isSpeaking { self.onEvent?(.speaking(false)); self.onEvent?(.idle) }
        }
    }
}
