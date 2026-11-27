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
    static let sessionKey = "xool.voice.session"
    static let pauseKey = "xool.voice.pause"
    static let wakeKey = "xool.voice.wake"
    static let readAloudKey = "xool.voice.readAloud"
    static let autoLiveKey = "xool.voice.autoLive"

    /// How long a quiet moment ends your sentence, in seconds.
    static var pause: Double { let v = Store.settings.double(forKey: pauseKey); return v > 0 ? v : 0.5 }

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
    /// After "Jarvis …" or an answer, follow-ups need no name for this many seconds.
    @Published var sessionSeconds: Double {
        didSet { Store.settings.set(sessionSeconds, forKey: Self.sessionKey) }
    }
    @Published var pauseSeconds: Double {
        didSet { Store.settings.set(pauseSeconds, forKey: Self.pauseKey); if handsFree { engine?.listen(.vad, bargeIn: bargeIn) } }
    }
    /// "Hey Jarvis" wakes him (openWakeWord, installed on request).
    @Published var wakeWord: Bool {
        didSet { Store.settings.set(wakeWord, forKey: Self.wakeKey); engine?.wake(wakeWord) }
    }
    /// The ears are loaded and warm.
    @Published private(set) var warm = false
    /// Live: the microphone stays open, what you say shows up in the thread as you speak and goes to the agent at
    /// the end of the sentence (also called the conversation).
    @Published private(set) var conversing = false
    /// What you have said so far in the sentence that is still going (the live bubble in the thread).
    @Published private(set) var partial: String?
    /// You are talking right now (the live bubble shows before the first words are understood).
    @Published private(set) var hearing = false
    /// Every answer is read aloud while Live is on (typed questions too).
    @Published var readAloud: Bool {
        didSet { Store.settings.set(readAloud, forKey: Self.readAloudKey) }
    }
    /// Opening Jarvis' thread starts Live by itself.
    @Published var autoLive: Bool {
        didSet { Store.settings.set(autoLive, forKey: Self.autoLiveKey); syncLive() }
    }
    private var liveStarting = false
    /// Live was ended by hand: it doesn't start again until Jarvis' thread is opened anew.
    private var userStoppedLive = false

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
        var kind = "erzaehlung"
        var route = ""
        var closing = false
        var started = Date()
    }

    init() {
        key = Store.settings.string(forKey: Self.keyKey) ?? "fn"
        bargeIn = Store.settings.object(forKey: Self.bargeKey) as? Bool ?? true
        sessionSeconds = Store.settings.object(forKey: Self.sessionKey) as? Double ?? 20
        pauseSeconds = Self.pause
        wakeWord = Store.settings.bool(forKey: Self.wakeKey)
        readAloud = Store.settings.object(forKey: Self.readAloudKey) as? Bool ?? true
        autoLive = Store.settings.object(forKey: Self.autoLiveKey) as? Bool ?? true
        keys.kind = key
        keys.onChange = { [weak self] down in self?.pressed(down) }
        AgentStore.shared.$threads.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pump() }.store(in: &cancellables)
        ChatRuntime.shared.$thinking.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pump() }.store(in: &cancellables)
        // Live follows Jarvis' thread: open it and he listens, leave it and the microphone closes.
        let ui = XoolUI.shared
        ui.$front.combineLatest(ui.$minimized).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncLive() }.store(in: &cancellables)
    }

    /// Starts watching the key and, if the better voice is set up, the sidecar: it
    /// loads the ears and the phrases now and stays warm, so the first word is understood at once.
    func install() { keys.install(); autostart() }

    /// The voice's state for the office and the menu bar.
    var status: VoiceStatus {
        if LocalSetup.shared.running { return .installing }
        switch state {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .idle: break
        }
        if !SidecarEngine.installed { return .missing }
        return warm ? .ready : .starting
    }

    /// What the model is told about its own ears and mouth.
    var abilities: String {
        "You can hear and speak. The user talks to you with the microphone (Live: it stays open and what they say reaches you "
        + "at the end of each sentence; or the key ⌥⌘J) and you answer aloud with your own voice; spoken text arrives like typed text. "
        + "Never say that you can't receive speech or answer aloud. "
        + (SidecarEngine.installed
           ? "Your own voice (Whisper and Piper, on this Mac) is set up."
           : "Your own voice isn't set up yet: the card “Set up the voice” in your office installs it (about 3 GB); until then you speak with the Mac's own voice.")
    }

    private var restarts: [Date] = []

    func autostart() {
        guard SidecarEngine.installed, !(engine is SidecarEngine) else { return }
        _ = ensureEngine()
    }

    private func scheduleRestart() {
        restarts = restarts.filter { Date().timeIntervalSince($0) < 300 } + [Date()]
        guard SidecarEngine.installed, restarts.count <= 3 else {
            notice = VoiceNotice(text: "The voice stopped. Press the key again to start it.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.autostart() }
    }

    /// Asks Ollama to keep the models for a conversation loaded, so the first answer isn't a cold start.
    private func warmModels() {
        let names = Set([OllamaCatalog.shared.quickVoice()?.model, ModelStore.shared.current?.model, ModelRouter.shared.configured(.agent)?.model, DecisionModel.model()?.model].compactMap { $0 })
        guard Store.settings.bool(forKey: "xool.voice.keepWarm") || Store.settings.object(forKey: "xool.voice.keepWarm") == nil else { return }
        for name in names where OllamaCatalog.shared.installed.contains(where: { $0.name == name }) {
            Task { _ = await AIClient.shared.ollama("api/generate", method: "POST", body: ["model": name, "prompt": "", "keep_alive": "60m"], timeout: 120) }
        }
    }

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
        warm = false
        state = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.autostart() }
    }

    var usesSidecar: Bool { engine is SidecarEngine }

    // MARK: who, and permission

    /// The thread to talk in: the one in front, else the agent used last.
    private func pickThread() -> UUID? {
        let ui = XoolUI.shared, store = AgentStore.shared
        // Jarvis, called by his key, the menu bar, the App Intent or ⌥-click.
        if forcedJarvis {
            forcedJarvis = false
            ui.openAgent(store.jarvis.id)
            return ui.front
        }
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
        if getenv("XOOL_VOICE_FAKEMIC") != nil, Store.testing || getenv("XOOL_PROFILE") != nil { then(); return }
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
        liveStarting = false
        Self.log("microphone: not allowed for Xool OS")
        notice = VoiceNotice(text: "Xool OS can't hear you: the microphone is off for it. After an update macOS asks again; switch it on under Privacy & Security › Microphone.",
                             settings: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
    }

    // MARK: dictation

    /// Speech into a text field instead of a thread: the address field, the
    /// thread's own field. Click to start, click to finish (the words go to
    /// `deliver`), Esc to throw it away.
    @Published private(set) var dictating = false
    private var dictation: ((String) -> Void)?
    private var discardNext = false
    private var escape: Any?

    func toggleDictation(_ deliver: @escaping (String) -> Void) {
        if dictating { finishDictation(); return }
        guard !holding, !handsFree else { return }
        notice = nil
        interrupt()
        guard let engine = ensureEngine() else { return }
        discardNext = false
        dictation = deliver
        withMicrophone { [weak self] in
            guard let self, self.dictation != nil else { return }
            self.dictating = true
            self.state = .listening
            engine.ptt(down: true)
            self.escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, self?.dictating == true else { return event }
                MainActor.assumeIsolated { self?.cancelDictation() }
                return nil
            }
        }
    }

    private func finishDictation() {
        guard dictating else { return }
        dictating = false
        stopEscapeWatch()
        guard state == .listening, let engine else { dictation = nil; state = .idle; return }
        state = .thinking
        pttPending = true
        engine.ptt(down: false)
    }

    func cancelDictation() {
        guard dictating || dictation != nil else { return }
        discardNext = state == .listening || state == .thinking
        dictation = nil
        dictating = false
        stopEscapeWatch()
        if state == .listening || state == .thinking { state = .idle }
        engine?.ptt(down: false)
    }

    private func stopEscapeWatch() {
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    // MARK: Jarvis' own entries (docs/PLAN.md 8, G)

    private var forcedJarvis = false
    /// Listening stays open after a short press, until the next one.
    @Published private(set) var latched = false
    private var jarvisDownAt = Date.distantPast

    /// The global key ⌥⌘J: held = push to talk, pressed briefly = listening
    /// until you press it again.
    func jarvisKey(down: Bool) {
        if down {
            if latched { latched = false; pressed(false); return }
            jarvisDownAt = Date()
            forcedJarvis = true
            pressed(true)
            if !holding { forcedJarvis = false }
        } else if !down, holding, !latched {
            if Date().timeIntervalSince(jarvisDownAt) < 0.4 {
                // A short press: the conversation (microphone open, no key per sentence).
                if SidecarEngine.installed {
                    pttPending = false
                    discardNext = true
                    pressed(false)
                    toggleConversation()
                } else { latched = true }
            } else { pressed(false) }
        }
    }

    /// Listen to Jarvis now, as a click does (menu bar, App Intent, ⌥-click on
    /// his pill); a second call ends it.
    func listenToJarvis() {
        if conversing || handsFree { toggleConversation(); return }
        if SidecarEngine.installed { toggleConversation(); return }
        if latched || holding { latched = false; pressed(false); return }
        latched = true
        forcedJarvis = true
        pressed(true)
        if !holding { forcedJarvis = false; latched = false }
    }

    /// Whether the voice is taking in what you say (the menu bar pulses).
    var listeningNow: Bool { state == .listening || holding }

    // MARK: push to talk

    /// The key went down or up.
    func pressed(_ down: Bool) {
        if down {
            guard !holding, !dictating else { return }
            holding = true
            notice = nil
            interrupt()
            guard let thread = pickThread(), let engine = ensureEngine() else { holding = false; return }
            target = thread
            Self.log("listening: down, agent \(AgentStore.shared.thread(thread).flatMap { AgentStore.shared.agent($0.agentID)?.name } ?? "?")")
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
            latched = false
            guard state == .listening, let engine else { return }
            state = .thinking
            pttPending = true
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

    /// Live with Jarvis (⌥⌘J pressed briefly, the waveform in his office, the menu bar): the microphone stays open,
    /// a pause ends your sentence, you talk over him to stop him, and for a while after each answer he needs no
    /// name. Without the better voice it listens once, until you press again.
    func toggleConversation() {
        if handsFree || conversing { userStoppedLive = true; endLive(); return }
        guard let engine = ensureEngine() else { return }
        guard engine.handsFree else {
            if latched || holding { latched = false; pressed(false) } else {
                latched = true; forcedJarvis = true; pressed(true)
                if !holding { forcedJarvis = false; latched = false }
            }
            return
        }
        forcedJarvis = true
        let thread = pickThread()
        forcedJarvis = false
        guard let thread else { return }
        userStoppedLive = false
        startLive(in: thread)
    }

    /// The Live button of a thread: on and off, for that thread's agent.
    func toggleLive(in thread: UUID) {
        if conversing || handsFree { userStoppedLive = true; endLive(); return }
        userStoppedLive = false
        startLive(in: thread)
    }

    /// Whether Live is on for this thread.
    func isLive(_ thread: UUID) -> Bool { (conversing || handsFree) && target == thread }

    func startLive(in thread: UUID) {
        guard !conversing, !handsFree, !liveStarting else { return }
        guard let engine = ensureEngine() else { return }
        guard engine.handsFree else {
            notice = VoiceNotice(text: "Live needs the better voice (Whisper and Piper).", setup: true)
            return
        }
        notice = nil
        target = thread
        liveStarting = true
        withMicrophone { [weak self] in
            guard let self, self.liveStarting else { return }
            self.liveStarting = false
            self.handsFree = true
            self.conversing = true
            self.state = .listening
            self.partial = nil
            self.hearing = false
            engine.listen(.vad, bargeIn: self.bargeIn)
            self.openSession()
            Self.log("live on (\(AgentStore.shared.thread(thread).flatMap { AgentStore.shared.agent($0.agentID)?.name } ?? "?"))")
        }
    }

    func endLive() {
        liveStarting = false
        guard conversing || handsFree else { return }
        conversing = false
        handsFree = false
        partial = nil
        hearing = false
        sessionUntil = .distantPast
        engine?.listen(.off, bargeIn: bargeIn)
        interrupt()
        state = .idle
        if let target { ChatRuntime.shared.setActivity(target, .idle) }
        Self.log("live off")
    }

    /// Jarvis' thread in front → Live starts (unless you ended it yourself); any other view → it ends.
    private func syncLive() {
        if getenv("XOOL_LIVE_AUTO") == nil, Store.testing || getenv("XOOL_PROFILE") != nil { return }
        let ui = XoolUI.shared, store = AgentStore.shared
        let front = ui.minimized ? nil : ui.front
        let onJarvis = front.flatMap { store.thread($0) }?.agentID == store.jarvis.id
        if let front, onJarvis {
            if autoLive, !conversing, !handsFree, !userStoppedLive, !dictating, !holding, SidecarEngine.installed { startLive(in: front) }
        } else {
            userStoppedLive = false
            if (conversing || handsFree) && target != front { endLive() }
        }
    }

    /// The Test voice button: one sentence, aloud.
    func testVoice() {
        guard let engine = ensureEngine() else { return }
        Self.log("test voice (\(engineName))")
        interrupt()
        engine.say(Self.language.hasPrefix("de") ? "Hallo, hier ist Jarvis. Wenn du mich hörst, funktioniert meine Stimme."
                   : "Hello, this is Jarvis. If you can hear me, my voice works.", first: true)
    }

    // MARK: who is meant

    private var sessionUntil = Date.distantPast
    /// A turn you started yourself (key, button, dictation): no need to ask whom you meant.
    private var pttPending = false
    private var wokeAt = Date.distantPast

    var sessionOpen: Bool { Date() < sessionUntil }

    private func openSession() { sessionUntil = Date().addingTimeInterval(sessionSeconds) }

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
        Self.log("event \(event)")
        switch event {
        case .ready: loading = nil
        case .warm:
            warm = true
            loading = nil
            engine?.wake(wakeWord)
            warmModels()
        case .wake:
            wokeAt = Date()
            openSession()
            Self.log("wake word heard")
        case .loading(let what): loading = what == "ears" ? "Getting the ears ready. The first time this downloads about 1.5 GB." : nil
        case .partial(let text):
            if conversing || handsFree { partial = text; hearing = true }
        case .speechStart:
            partial = nil
            hearing = true
            // Hands-free: you started talking, to the agent in front.
            if handsFree, !holding {
                if conversing, let thread = target { ChatRuntime.shared.setActivity(thread, .listening) }
                else if let thread = pickThread() { target = thread; ChatRuntime.shared.setActivity(thread, .listening) }
                state = .listening
                lastActivity = Date()
            }
        case .bargeIn:
            partial = nil
            if let s = session { ChatRuntime.shared.stop(s.thread) }
            session = nil
            state = .listening
        case .transcript(let text, let info): heard(text, info: info)
        case .speaking(let on):
            if on { state = .speaking }
        case .idle:
            if session?.finished ?? true {
                if let done = session, done.sentAny { if done.closing { sessionUntil = .distantPast } else { openSession() } }
                session = nil
                if state == .speaking || state == .thinking { state = handsFree ? .listening : .idle }
                afterAnswer()
            }
        case .bridge: break
        case .error(let text, let mic, let fatal):
            notice = VoiceNotice(text: text, settings: mic ? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") : nil,
                                 setup: fatal && !SidecarEngine.installed)
            if fatal {
                engine = nil; state = .idle; holding = false; handsFree = false; conversing = false; warm = false; partial = nil; hearing = false
                notice = nil
                scheduleRestart()
            }
        }
    }

    /// What you said. With a key or button you meant it; in a conversation the sentence first has to be
    /// meant for Jarvis (his name, an open session, or the small model says so).
    private func heard(_ raw: String, info given: Heard) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = nil
        hearing = false
        // The Mac's own recognition brings no judgement: make the instant one here.
        let info = given.route.isEmpty && !text.isEmpty ? QuickJudge.judge(text, name: AgentStore.shared.jarvis.name) : given
        if discardNext { discardNext = false; state = handsFree ? .listening : .idle; return }
        if let deliver = dictation {
            dictation = nil
            dictating = false
            state = .idle
            if !text.isEmpty { deliver(text) }
            return
        }
        guard let thread = target else { state = handsFree ? .listening : .idle; return }
        ChatRuntime.shared.setActivity(thread, .idle)
        guard !text.isEmpty else { state = handsFree ? .listening : .idle; return }
        let explicit = pttPending || !handsFree
        pttPending = false
        if explicit || info.named || Date().timeIntervalSince(wokeAt) < 12 {
            accept(text, info, thread)
            return
        }
        let inSession = sessionOpen
        let recent = (AgentStore.shared.thread(thread)?.messages ?? []).filter { !$0.text.isEmpty }.suffix(3).map { ($0.role == .user ? "Person: " : "Assistant: ") + $0.text }
        let name = AgentStore.shared.jarvis.name
        Task { @MainActor [weak self] in
            // A very short fragment outside a conversation is almost never for him.
            let verdict = await DecisionModel.addressed(text, name: name, recent: recent, inSession: inSession)
            guard let self else { return }
            let meant = verdict ?? inSession
            guard meant else {
                Self.log("ignored (not meant for \(name)): \(text)")
                if Store.testing { FileHandle.standardError.write(Data("voice ignored: \(text)\n".utf8)) }
                self.state = self.handsFree ? .listening : .idle
                return
            }
            self.accept(text, info, thread)
        }
    }

    /// The sentence is for Jarvis: bridge phrase, then the answer, read aloud as it is written.
    private func accept(_ text: String, _ info: Heard, _ thread: UUID, bridging: Bool = true) {
        lastActivity = Date()
        openSession()
        let now = Date()
        // Notes the thinker made in the pause, and how to answer a listener.
        ChatRuntime.shared.extra[thread] = Self.spokenStyle(now) + (notes[thread].map { "\n\nBackground notes you prepared (use only if they fit, don't mention them):\n" + $0 } ?? "")
        notes[thread] = nil
        // The instant judgement says whether the model's own knowledge is enough or tools are needed.
        let decision = info.route.isEmpty ? nil : Decision(needsTools: info.tools, preferCloud: false, decided: true)
        ChatRuntime.shared.send(text, in: thread, decision: decision, spoken: true)
        guard let last = AgentStore.shared.thread(thread)?.messages.last, last.role == .assistant else { state = .idle; return }
        var s = Session(thread: thread, message: last.id)
        s.kind = info.kind.isEmpty ? "erzaehlung" : info.kind
        s.route = info.route
        s.closing = info.kind == "abschied"
        s.started = now
        session = s
        state = .thinking
        // The bridge phrase: at once when the answer will take a while (tools, thinking); a moment's grace
        // when the quick model usually has its first sentence ready by then.
        let id = last.id
        guard bridging else { return }
        let quick = (info.route.isEmpty || info.route == "wissen") && firstSentenceAverage > 0 && firstSentenceAverage < 0.6
        Task { @MainActor [weak self] in
            if quick { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard let self, let s = self.session, s.message == id, !s.sentAny, !s.bridged else { return }
            self.session?.bridged = true
            self.engine?.bridge(s.kind)
            Self.log("bridge \(s.kind) after \(Int(Date().timeIntervalSince(s.started) * 1000)) ms")
        }
        // Still nothing after a while (a page that loads slowly): a second, calm phrase.
        Task { @MainActor [weak self] in
            for wait in [9.0, 12.0] {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, let s = self.session, s.message == id, !s.sentAny else { return }
                self.engine?.bridge("warten")
            }
        }
    }

    /// A message typed to an agent. With Live on (and "Read replies aloud") the answer is spoken too: sentence by
    /// sentence, without markdown, as for a spoken question.
    func typed(_ text: String, in thread: UUID) {
        let chat = ChatRuntime.shared
        let isJarvis = AgentStore.shared.thread(thread)?.agentID == AgentStore.shared.jarvis.id
        guard readAloud, isJarvis, conversing || handsFree, engine != nil, !chat.thinking.contains(thread) else {
            chat.send(text, in: thread)
            return
        }
        interrupt()
        target = thread
        Self.log("typed message, the answer will be spoken")
        accept(text.trimmingCharacters(in: .whitespacesAndNewlines), Heard(), thread, bridging: false)
    }

    /// How a spoken answer is written: for the ear, in the user's language.
    static func spokenStyle(_ now: Date = Date()) -> String {
        let clock = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        return """
        You are in a spoken conversation: the user talks to you and your answer is read aloud. You have ears and a voice; never say you \
        can't hear or speak. Answer in the language the user spoke (usually German), in one to three short, natural sentences, the way \
        you would say it to a person next to you. No markdown, no lists, no headings, no emoji, no links read out (name the site instead). \
        Write numbers, times and units the way they are said. Start with the answer itself, no filler like "Gladly!" (a short \
        acknowledgement was already spoken). When the web, the browser or the user's notes are needed, \
        use the tools straight away, without announcing first (a phrase like "I'm having a look" was already spoken), and answer from what \
        they return. Never end a turn by only saying what you are about to do. After the tools: the answer, short, with the one or two most \
        important facts. Offer more at the end. Now: \(clock).
        """
    }

    /// Said when an answer failed, so a spoken question never gets silence.
    static var apology: String {
        language.hasPrefix("de") ? "Das hat leider nicht geklappt. Schau bitte in den Thread." : "That didn't work. Please look at the thread."
    }

    /// How quickly the first sentence usually comes (seconds), to decide whether a bridge phrase is needed at once.
    private var firstSentenceAverage = 0.0

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
                Self.log("say: \(piece)")
                if !s.sentAny {
                    let took = Date().timeIntervalSince(s.started)
                    firstSentenceAverage = firstSentenceAverage == 0 ? took : firstSentenceAverage * 0.6 + took * 0.4
                    Self.log("first sentence after \(Int(took * 1000)) ms (\(s.route.isEmpty ? "?" : s.route))")
                }
                engine.say(piece, first: !s.sentAny)
                s.sentAny = true
            }
        }
        // The agent started working with nothing said: say so with a phrase.
        if !s.sentAny, !s.bridged, !(message.steps?.isEmpty ?? true) {
            s.bridged = true
            engine.bridge(s.route == "browser" ? "browser" : s.route == "brain" ? "brain" : "websuche")
        }
        if !s.finished, !ChatRuntime.shared.thinking.contains(s.thread) {
            s.finished = true
            for piece in s.chunker.flush() {
                if Store.testing { FileHandle.standardError.write(Data("voice say: \(piece)\n".utf8)) }
                engine.say(piece, first: !s.sentAny); s.sentAny = true
            }
            if !s.sentAny {
                // Stopped by you: silence. Anything else that left nothing to read (an error the thread
                // shows): a spoken apology, never silence after a spoken question.
                if let failed = message.failed, failed != "Stopped." {
                    engine.say(Self.apology, first: true)
                    s.sentAny = true
                } else {
                    session = nil
                    state = handsFree ? .listening : .idle
                    return
                }
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

    /// A line for the voice log (~/Library/Logs/Xool/voice.log).
    nonisolated static func log(_ line: String) { VoiceLog.write(line) }

    /// Test runs: a WAV file said to Jarvis, as the key, the menu bar and the Intent do.
    func feedJarvis(file: URL) {
        forcedJarvis = true
        feed(file: file)
    }

    /// Test runs: a WAV file as if the microphone in conversation mode had picked it up: whether it is
    /// meant for Jarvis is decided (name, open session, the small model), not assumed.
    func feedConversation(file: URL, open: Bool) {
        forcedJarvis = true
        guard let thread = pickThread(), let engine = ensureEngine() else { return }
        forcedJarvis = false
        target = thread
        handsFree = true
        conversing = true
        pttPending = false
        sessionUntil = open ? Date().addingTimeInterval(sessionSeconds) : .distantPast
        state = .listening
        engine.transcribe(file: file)
    }

    /// Test runs: a WAV the fake microphone (XOOL_VOICE_FAKEMIC) hears after `delay` seconds.
    func feedMic(_ path: String, delay: Double) { (engine as? SidecarEngine)?.feedMic(path, delay: delay) }

    /// Test runs: the recording of what the sidecar said (`--record`, XOOL_VOICE_RECORD).
    func saveOutput(to path: String) { (engine as? SidecarEngine)?.saveOutput(to: path) }

    /// Test runs: a WAV file in place of the microphone.
    func feed(file: URL) {
        guard let thread = pickThread(), let engine = ensureEngine() else { return }
        pttPending = true
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
