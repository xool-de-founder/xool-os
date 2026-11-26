import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox

// Talking to Jarvis from outside the app (docs/PLAN.md 8, G): a global key
// (⌥⌘J, held = push to talk, pressed briefly = listen until you press it
// again), a menu-bar icon (click = listen, the icon pulses; right-click = the
// menu), and the App Intent "Talk to Jarvis" (JarvisIntent.swift).

/// The global key as chosen: ⌥⌘J until you say otherwise.
struct JarvisKeyChoice: Codable, Equatable {
    var combo: KeyCombo
    var code: UInt16
    static let standard = JarvisKeyChoice(combo: KeyCombo("j", option: true), code: UInt16(kVK_ANSI_J))
}

@MainActor
final class JarvisEntry: ObservableObject {
    static let shared = JarvisEntry()
    static let keyKey = "xool.jarvis.key"
    static let keyOnKey = "xool.jarvis.keyOn"
    static let menuBarKey = "xool.jarvis.menubar"

    @Published var keyOn: Bool { didSet { Store.settings.set(keyOn, forKey: Self.keyOnKey); refreshKey() } }
    @Published var choice: JarvisKeyChoice { didSet { save(); refreshKey() } }
    @Published var menuBar: Bool { didSet { Store.settings.set(menuBar, forKey: Self.menuBarKey); refreshItem() } }
    /// Why macOS wouldn't have the key (another app's, or its own), or nil.
    @Published private(set) var refusal: String?

    private var item: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        keyOn = Store.settings.object(forKey: Self.keyOnKey) as? Bool ?? true
        menuBar = Store.settings.object(forKey: Self.menuBarKey) as? Bool ?? true
        choice = Store.settings.data(forKey: Self.keyKey).flatMap { try? JSONDecoder().decode(JarvisKeyChoice.self, from: $0) } ?? .standard
    }

    private func save() {
        if let data = try? JSONEncoder().encode(choice) { Store.settings.set(data, forKey: Self.keyKey) }
    }

    /// Once, when the app is up: the key, the icon, and what pulses it.
    func install() {
        VoiceHotKey.changed = { down in VoiceBridge.shared.jarvisKey(down: down) }
        refreshKey()
        refreshItem()
        guard cancellables.isEmpty else { return }
        Publishers.CombineLatest(VoiceBridge.shared.$state, VoiceBridge.shared.$latched)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pulse() }.store(in: &cancellables)
    }

    func refreshKey() {
        guard keyOn else { VoiceHotKey.clear(); refusal = nil; return }
        let modifiers = HotKey.modifiers(of: choice.combo)
        if HotKey.usedByMacOS(code: choice.code, modifiers: modifiers) {
            VoiceHotKey.clear()
            refusal = "macOS uses \(choice.combo.display). Choose another key"
            return
        }
        let status = VoiceHotKey.set(code: choice.code, modifiers: modifiers)
        refusal = status == noErr ? nil : "\(choice.combo.display) belongs to another app. Choose another key"
    }

    // MARK: the menu-bar icon

    func refreshItem() {
        guard menuBar else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }
        let made = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = made.button {
            button.image = XoolMarkShape.templateImage(side: 16)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Talk to Jarvis")
            button.toolTip = "Talk to Jarvis. Right-click for more"
            button.wantsLayer = true
        }
        item = made
    }

    var statusButton: NSStatusBarButton? { item?.button }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            VoiceBridge.shared.listenToJarvis()
        }
    }

    /// Right-click: recent threads, open Xool, the voice switched off or on.
    private func showMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Voice: \(VoiceBridge.shared.status.title)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if VoiceBridge.shared.status == .missing {
            let setup = NSMenuItem(title: "Set up the voice…", action: #selector(setupVoice), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }
        let talking = VoiceBridge.shared.listeningNow || VoiceBridge.shared.conversing
        let talk = NSMenuItem(title: talking ? "End the conversation" : "Talk to Jarvis", action: #selector(talk), keyEquivalent: "")
        talk.target = self
        menu.addItem(talk)
        let store = AgentStore.shared
        let recent = store.threads.sorted { $0.updated > $1.updated }.filter { !$0.messages.isEmpty }.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent threads", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for thread in recent {
                let who = store.agent(thread.agentID)?.name ?? "Agent"
                let entry = NSMenuItem(title: "\(who): \(thread.title)", action: #selector(openThread(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = thread.id
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Xool OS", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let voice = NSMenuItem(title: keyOn ? "Voice shortcut off" : "Voice shortcut on", action: #selector(toggleKey), keyEquivalent: "")
        voice.target = self
        menu.addItem(voice)
        if let button = item?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func talk() { VoiceBridge.shared.listenToJarvis() }
    /// The card with the button is in Jarvis' office.
    @objc private func setupVoice() {
        openApp()
        XoolUI.shared.showAgents = true
    }
    @objc private func openApp() { NSApp.activate(ignoringOtherApps: true); Browsers.frontBrowser.window?.makeKeyAndOrderFront(nil) }
    @objc private func toggleKey() { keyOn.toggle() }
    @objc private func openThread(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openApp()
        XoolUI.shared.openThread(id)
    }

    /// The icon breathes while the voice takes in what you say.
    private func pulse() {
        guard let layer = item?.button?.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        guard VoiceBridge.shared.listeningNow, !Motion.reduced else {
            item?.button?.alphaValue = VoiceBridge.shared.listeningNow ? 1 : 0.9
            return
        }
        item?.button?.alphaValue = 1
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1; breathe.toValue = 0.3
        breathe.duration = 0.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathe, forKey: "pulse")
    }
}

// MARK: - Settings

/// The global key, chosen in Settings: click, then press it. ⌫ turns it off.
struct JarvisKeyBox: View {
    @ObservedObject private var entry = JarvisEntry.shared
    @XState private var listening = false
    @XState private var monitor: Any?
    @XState private var note: String?
    @XState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let refusal = entry.refusal, !listening {
                Text(refusal).font(.system(size: 11)).foregroundStyle(Color.red.opacity(0.8)).lineLimit(1)
            }
            Button(action: listen) {
                Text(note ?? (listening ? "Type a shortcut" : entry.keyOn ? entry.choice.combo.display : "Off"))
                    .font(.system(size: 12))
                    .foregroundStyle(listening || entry.keyOn ? Palette.ink : Palette.muted)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 64, minHeight: 24)
                    .background(listening || hovering ? Palette.hover : Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(listening ? Palette.ink.opacity(0.4) : Palette.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click, then press the key. ⌫ turns it off")
            .onHover { hovering = $0 }
            .onDisappear(perform: stop)
            .accessibilityLabel("Shortcut to talk to Jarvis from any app")
        }
    }

    private func listen() {
        guard !listening else { return stop() }
        listening = true
        note = nil
        ShortcutStore.shared.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in take(event); return nil }
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { return stop() }
        if [51, 117].contains(event.keyCode), flags.isEmpty { entry.keyOn = false; return stop() }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else { return say("Add ⌘, ⌥ or ⌃") }
        guard !KeyCombo.isReserved(combo) else { return say("Can’t be used") }
        guard !HotKey.usedByMacOS(code: event.keyCode, modifiers: HotKey.modifiers(of: combo)) else { return say("Used by macOS") }
        entry.choice = JarvisKeyChoice(combo: combo, code: event.keyCode)
        entry.keyOn = true
        stop()
    }

    private func say(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if note == text { note = nil } }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        note = nil
        ShortcutStore.shared.recording = false
    }
}
