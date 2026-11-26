import Foundation
import AppKit
import AVFoundation
import Combine

/// What the voice is doing right now.
enum VoiceState: Equatable { case idle, listening, thinking, speaking }

/// A line the thread shows about the voice: what is wrong and what to do.
struct VoiceNotice: Equatable {
    var text: String
    /// A System Settings page that fixes it.
    var settings: URL?
    /// Offers the setup of the better voice.
    var setup = false
}

/// Talking to an agent. The engine hears and speaks; this decides who is
/// meant, hands the words to the thread (so an agent works with its browser
/// tools exactly as when you type), and reads the answer aloud sentence by
/// sentence while it is still being written. Talk over it (or press the
/// key again) and it falls silent and stops at once.
@MainActor
final class VoiceBridge: ObservableObject {
    static let shared = VoiceBridge()

    static let keyKey = "xool.voice.key"
    static let bargeKey = "xool.voice.bargeIn"
    static let languageKey = "xool.voice.language"

    /// What you speak: the Mac's first language, German until you say otherwise.
    static var language: String {
        if let set = Store.settings.string(forKey: languageKey), !set.isEmpty { return set }
        return Locale.preferredLanguages.first.map { $0.contains("-") ? $0 : $0 } ?? "de-DE"
    }

    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var handsFree = false
    @Published var notice: VoiceNotice?
    /// What is still being fetched the first time ("Getting the ears ready").
    @Published private(set) var loading: String?
    @Published private(set) var engineName = ""
    /// The thread the voice is talking in.
    @Published private(set) var target: UUID?
    @Published var key: String {
        didSet { Store.settings.set(key, forKey: Self.keyKey); keys.kind = key }
    }
    @Published var bargeIn: Bool {
        didSet { Store.settings.set(bargeIn, forKey: Self.bargeKey); if handsFree { engine?.listen(.vad, bargeIn: bargeIn) } }
    }

    private var engine: VoiceEngine?
    private let keys = PushToTalkKey()
    private var cancellables: Set<AnyCancellable> = []
    private var session: Session?
    private var holding = false
    private var lastActivity = Date()
    private var thinker: Task<Void, Never>?

    /// One spoken exchange: which message is being read out and how far.
    private struct Session {
        var thread: UUID
        var message: UUID
        var consumed = 0
        var chunker = SpeechChunker()
        var sentAny = false
        var bridged = false
        var finished = false
    }

    init() {
        key = Store.settings.string(forKey: Self.keyKey) ?? "fn"
        bargeIn = Store.settings.object(forKey: Self.bargeKey) as? Bool ?? true
        keys.kind = key
        keys.onChange = { [weak self] down in self?.pressed(down) }
        AgentStore.shared.$threads.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pump() }.store(in: &cancellables)
        ChatRuntime.shared.$thinking.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pump() }.store(in: &cancellables)
    }

    /// Starts watching the key. Called once when the interface comes up.
    func install() { keys.install() }

    // MARK: engine

    private func ensureEngine() -> VoiceEngine? {
        if let engine { return engine }
        let candidates: [VoiceEngine] = SidecarEngine.installed ? [SidecarEngine(), NativeEngine()] : [NativeEngine()]
        for candidate in candidates {
            candidate.onEvent = { [weak self] event in self?.handle(event) }
            do {
                try candidate.start()
                engine = candidate
                engineName = candidate.name
                return candidate
            } catch { continue }
        }
        notice = VoiceNotice(text: "The voice couldn't start.", setup: true)
        return nil
    }

    func restart() {
        engine?.shutdown()
        engine = nil
        session = nil
        state = .idle
    }

    var usesSidecar: Bool { engine is SidecarEngine }

    // MARK: who, and permission

    /// The thread to talk in: the one in front, else the agent used last.
    private func pickThread() -> UUID? {
        let ui = XoolUI.shared, store = AgentStore.shared
        if let front = ui.front, store.thread(front) != nil, !ui.minimized { return front }
        guard let agent = store.byActivity.first else {
            notice = VoiceNotice(text: "Make an agent first (+ in the bar), then talk to it.")
            return nil
        }
        ui.openAgent(agent.id)
        return ui.front
    }

    /// Microphone access: asks once, with our own words; denied is explained.
    private func withMicrophone(_ then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: then()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { then() } else { self.denied() }
                }
            }
        default: denied()
        }
    }

    private func denied() {
        holding = false
        notice = VoiceNotice(text: "Xool OS can't hear you: the microphone is off for it.",
                             settings: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
    }

    // MARK: push to talk

    /// The key went down or up.
    func pressed(_ down: Bool) {
        if down {
            guard !holding else { return }
            holding = true
            notice = nil
            interrupt()
            guard let thread = pickThread(), let engine = ensureEngine() else { holding = false; return }
            target = thread
            lastActivity = Date()
            withMicrophone { [weak self] in
                guard let self, self.holding else { return }
                self.state = .listening
                ChatRuntime.shared.setActivity(thread, .listening)
                engine.ptt(down: true)
            }
        } else {
            guard holding else { return }
            holding = false
            guard state == .listening, let engine else { return }
            state = .thinking
            if let target { ChatRuntime.shared.setActivity(target, .thinking) }
            engine.ptt(down: false)
        }
    }

    /// The mic button in the thread: the key, as a click. Hands-free is a
    /// long press; see `toggleHandsFree`.
    func toggleHandsFree() {
        if handsFree {
            handsFree = false
            engine?.listen(.off, bargeIn: bargeIn)
            if state == .listening { state = .idle }
            if let target { ChatRuntime.shared.setActivity(target, .idle) }
            return
        }
        guard let engine = ensureEngine() else { return }
        guard engine.handsFree else {
            notice = VoiceNotice(text: "Hands-free needs the better voice. Push to talk works now.", setup: true)
            return
        }
        guard let thread = pickThread() else { return }
        target = thread
        withMicrophone { [weak self] in
            guard let self else { return }
            self.handsFree = true
            self.state = .listening
            engine.listen(.vad, bargeIn: self.bargeIn)
        }
    }

    /// Stop talking and thinking, now.
    func interrupt() {
        if Store.testing { FileHandle.standardError.write(Data("voice interrupt\n".utf8)) }
        thinker?.cancel()
        engine?.stop()
        if let s = session { ChatRuntime.shared.stop(s.thread) }
        session = nil
        if state == .speaking || state == .thinking { state = handsFree ? .listening : .idle }
    }

    // MARK: events

    private func handle(_ event: VoiceEvent) {
        if Store.testing { FileHandle.standardError.write(Data("voice event: \(event)\n".utf8)) }
        switch event {
        case .ready: loading = nil
        case .loading(let what): loading = what == "ears" ? "Getting the ears ready. The first time this downloads about 1.5 GB." : nil
        case .speechStart:
            // Hands-free: you started talking, to the agent in front.
            if handsFree, !holding {
                if let thread = pickThread() { target = thread; ChatRuntime.shared.setActivity(thread, .listening) }
                state = .listening
                lastActivity = Date()
            }
        case .bargeIn:
            if let s = session { ChatRuntime.shared.stop(s.thread) }
            session = nil
            state = .listening
        case .transcript(let text, let kind): heard(text, kind: kind)
        case .speaking(let on):
            if on { state = .speaking }
        case .idle:
            if session?.finished ?? true {
                session = nil
                if state == .speaking || state == .thinking { state = handsFree ? .listening : .idle }
                afterAnswer()
            }
        case .bridge: break
        case .error(let text, let mic, let fatal):
            notice = VoiceNotice(text: text, settings: mic ? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") : nil,
                                 setup: fatal && !SidecarEngine.installed)
            if fatal { engine = nil; state = .idle; holding = false; handsFree = false }
        }
    }

    /// What you said, as a message to the agent.
    private func heard(_ raw: String, kind: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread = target else { state = handsFree ? .listening : .idle; return }
        ChatRuntime.shared.setActivity(thread, .idle)
        guard !text.isEmpty else { state = handsFree ? .listening : .idle; return }
        lastActivity = Date()
        // Notes the thinker made in the pause, and how to answer a listener.
        ChatRuntime.shared.extra[thread] = Self.spokenStyle + (notes[thread].map { "\n\nBackground notes you prepared (use only if they fit, don't mention them):\n" + $0 } ?? "")
        notes[thread] = nil
        ChatRuntime.shared.send(text, in: thread)
        guard let last = AgentStore.shared.thread(thread)?.messages.last, last.role == .assistant else { state = .idle; return }
        session = Session(thread: thread, message: last.id)
        state = .thinking
        // A bridge phrase, only if the first sentence isn't there yet.
        let id = last.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, let s = self.session, s.message == id, !s.sentAny, !s.bridged else { return }
            self.session?.bridged = true
            self.engine?.bridge(kind)
        }
    }

    static let spokenStyle = """
    The user is talking to you and your answer is read aloud. Answer in the language they spoke, in one to three short, natural sentences, \
    no lists, no markdown, no links read out. When a task takes several steps, say in a few words what you are doing first. \
    Give the short version and offer more.
    """

    // MARK: reading the answer aloud

    /// The thread changed: speak what is new, as whole sentences.
    private func pump() {
        guard var s = session, let engine, let thread = AgentStore.shared.thread(s.thread),
              let message = thread.messages.first(where: { $0.id == s.message }) else { return }
        let text = message.text
        if text.count > s.consumed {
            let fresh = String(text.dropFirst(s.consumed))
            s.consumed = text.count
            for piece in s.chunker.feed(fresh) {
                if Store.testing { FileHandle.standardError.write(Data("voice say: \(piece)\n".utf8)) }
                engine.say(piece, first: !s.sentAny)
                s.sentAny = true
            }
        }
        // The agent started working with nothing said: say so with a phrase.
        if !s.sentAny, !s.bridged, !(message.steps?.isEmpty ?? true) {
            s.bridged = true
            engine.bridge("suche")
        }
        if !s.finished, !ChatRuntime.shared.thinking.contains(s.thread) {
            s.finished = true
            for piece in s.chunker.flush() {
                if Store.testing { FileHandle.standardError.write(Data("voice say: \(piece)\n".utf8)) }
                engine.say(piece, first: !s.sentAny); s.sentAny = true
            }
            if !s.sentAny {
                // Nothing to read (stopped, or an error the thread shows).
                session = nil
                state = handsFree ? .listening : .idle
                return
            }
        }
        session = s
    }

    // MARK: thinking ahead

    private var notes: [UUID: String] = [:]
    private var suggestion: String?

    /// In the pause after an answer a small local model prepares notes for the
    /// next turn; in hands-free mode and after a long quiet it may offer one
    /// "By the way …".
    private func afterAnswer() {
        guard let thread = target else { return }
        thinker?.cancel()
        thinker = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let made = await Thinker.think(thread: thread)
            guard !Task.isCancelled else { return }
            if let notes = made.notes { self.notes[thread] = notes }
            guard let line = made.suggestion, self.handsFree else { return }
            // Offered only after a long quiet, and only if nothing happened meanwhile.
            let since = self.lastActivity
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            guard !Task.isCancelled, self.lastActivity == since, self.state == .listening, self.session == nil else { return }
            self.engine?.say(line, first: true)
            self.lastActivity = Date()
        }
    }

    // MARK: tests

    /// Test runs: a WAV file in place of the microphone.
    func feed(file: URL) {
        guard let thread = pickThread(), let engine = ensureEngine() else { return }
        target = thread
        state = .thinking
        ChatRuntime.shared.setActivity(thread, .thinking)
        engine.transcribe(file: file)
    }
}

// MARK: - thinking ahead

@MainActor
enum Thinker {
    static let system = """
    You are the quiet background thinker of a voice assistant. Read the conversation. Write at most 5 short lines of notes that will help \
    with the likely next question: facts, likely follow-ups. Then one line starting with "SUGGESTION:" with one short friendly sentence \
    the assistant could offer on its own (an offer or a tip, never a question about feelings), in the language of the conversation. \
    If there is nothing worth offering write "SUGGESTION: -".
    """

    static func think(thread: UUID) async -> (notes: String?, suggestion: String?) {
        guard let choice = DecisionModel.model(), let provider = choice.aiProvider, provider != .thisMac,
              let messages = AgentStore.shared.thread(thread)?.messages.suffix(8), !messages.isEmpty else { return (nil, nil) }
        let convo = messages.filter { !$0.text.isEmpty }.map { ($0.role == .user ? "Person: " : "Assistant: ") + String($0.text.prefix(400)) }.joined(separator: "\n")
        let stream = AIClient.shared.stream(provider, model: choice.model, system: system, messages: [AIMessage(role: .user, text: convo)], key: nil)
        let reading = Task { () -> String in
            var said = ""
            do { for try await piece in stream { said += piece; if said.count > 900 { break } } } catch { return "" }
            return said
        }
        let timer = Task { try? await Task.sleep(nanoseconds: 25_000_000_000); reading.cancel() }
        let said = await reading.value
        timer.cancel()
        let text = said.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, nil) }
        var notes = text, suggestion: String?
        if let range = text.range(of: "SUGGESTION:") {
            notes = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let line = String(text[range.upperBound...]).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !["", "-", "–"].contains(line) { suggestion = line }
        }
        return (notes.isEmpty ? nil : notes, suggestion)
    }
}

// MARK: - the key

/// Holding `fn` (or ⌥Space) talks. fn also rides along with the arrow and
/// function keys, so a hold counts only after a moment with no other key.
@MainActor
final class PushToTalkKey {
    var kind = "fn"
    var onChange: ((Bool) -> Void)?
    private var monitors: [Any] = []
    private var armed: DispatchWorkItem?
    private var active = false

    func install() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) == true ? nil : event }
        }) { monitors.append(local) }
        // Other apps in front: works once macOS lets Xool OS see keys (Input Monitoring).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }) { monitors.append(global) }
    }

    /// True when the event was ours and shouldn't go on.
    private func handle(_ event: NSEvent) -> Bool {
        if kind == "optionSpace" {
            guard event.keyCode == 49 else { return false }
            if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option), !event.isARepeat {
                active = true; onChange?(true); return true
            }
            if event.type == .keyUp, active { active = false; onChange?(false); return true }
            return event.type == .keyDown && active
        }
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.function] {
                guard armed == nil, !active else { return false }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.armed = nil
                    self.active = true
                    self.onChange?(true)
                }
                armed = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            } else {
                armed?.cancel(); armed = nil
                if active { active = false; onChange?(false) }
            }
        case .keyDown:
            // fn + another key: not a hold to talk.
            armed?.cancel(); armed = nil
        default: break
        }
        return false
    }
}
