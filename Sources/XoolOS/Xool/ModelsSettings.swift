import SwiftUI

/// Settings › Models: where each provider stands, its key (keychain only,
/// sent only to the provider's own host), which model does which job, and
/// what Ollama has.
struct ModelsSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var router = ModelRouter.shared
    @ObservedObject private var catalog = OllamaCatalog.shared
    @ObservedObject private var engine = AIEngine.shared
    @XState private var checks: [AIProvider: Status] = [:]
    @XState private var pasted: [AIProvider: String] = [:]
    @XState private var hints: [AIProvider: String] = [:]
    @XState private var custom = ""

    enum Status: Equatable {
        case checking
        case connected(String)
        case kept
        case noKey
        case refused
        case down(String)

        var words: String {
            switch self {
            case .checking: return "Checking…"
            case .connected(let what): return "Connected · \(what)"
            case .kept: return "Key kept · not tested yet"
            case .noKey: return "No key"
            case .refused: return "Key refused. Paste a new one"
            case .down(let why): return why
            }
        }
        var symbol: String {
            switch self {
            case .checking: return "ellipsis.circle"
            case .connected: return "checkmark.circle.fill"
            case .kept: return "key"
            case .noKey: return "minus.circle"
            case .refused, .down: return "exclamationmark.triangle"
            }
        }
    }

    private static let cloud: [AIProvider] = [.anthropic, .openAI, .gemini, .openRouter]
    private static let onThisMac: [AIProvider] = [.ollama, .lmStudio, .thisMac]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Caption("Providers")
            Card {
                ForEach(Array(Self.cloud.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Rule() }
                    cloudRow(provider)
                }
            }
            Card {
                ForEach(Array(Self.onThisMac.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Rule() }
                    localRow(provider)
                }
            }
            Caption("Roles")
            Card {
                ForEach(Array(ModelRole.allCases.enumerated()), id: \.element) { index, role in
                    if index > 0 { Rule() }
                    roleRow(role)
                }
                Rule()
                Line("Use the cloud when local isn't enough",
                     "Off: nothing leaves this Mac. On: a local model that isn't running, or a request the Decision model finds too hard, goes to a cloud model you have a key for") {
                    Switch(on: $router.allowCloud)
                }
            }
            Caption("Local AI")
            LocalSetupCard()
            Caption("Ollama")
            ollamaCard
            Caption("Voice")
            VoiceSettingsCard()
        }
        .onAppear(perform: refresh)
    }

    // MARK: providers

    private func status(_ provider: AIProvider) -> Status {
        if let checked = checks[provider] { return checked }
        if provider.isLocal { return .checking }
        return hints[provider] == nil ? .noKey : .kept
    }

    private func statusLabel(_ provider: AIProvider) -> some View {
        let status = status(provider)
        return Label(status.words, systemImage: status.symbol)
            .font(Theme.small)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(2)
            .accessibilityLabel("\(provider.name): \(status.words)")
    }

    private func cloudRow(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                statusLabel(provider)
            }
            HStack(spacing: 6) {
                if let hint = hints[provider] {
                    Text("\(hint), in this Mac's keychain, sent only to \(provider.host)")
                        .font(Theme.small).foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 8)
                    Pill("Test connection") { test(provider) }
                    Pill("Forget") {
                        AIKeys.forget(provider)
                        checks[provider] = nil
                        refreshHints()
                        Task { await models.refresh() }
                    }
                } else {
                    SecureField("", text: Binding(get: { pasted[provider] ?? "" }, set: { pasted[provider] = $0 }),
                                prompt: Text("API key").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit { save(provider) }
                        .accessibilityLabel("\(provider.name) API key")
                    Pill("Save", filled: true) { save(provider) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func localRow(_ provider: AIProvider) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                Text(provider == .thisMac ? "The model Xool OS runs itself. Nothing leaves this Mac" : "On this Mac. No key needed")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            statusLabel(provider)
            Pill("Test connection") { test(provider) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func save(_ provider: AIProvider) {
        let key = pasted[provider] ?? ""
        pasted[provider] = nil
        switch AIKeys.save(key, for: provider) {
        case .kept: browser.announce("Key kept in the keychain")
        case .unavailable: browser.announce("This copy can't keep keys")
        case .failed: browser.announce("The key wasn't kept")
        }
        refreshHints()
        checks[provider] = nil
        Task { await models.refresh() }
    }

    private func test(_ provider: AIProvider) {
        checks[provider] = .checking
        Task { @MainActor in
            let result: AIClient.Check
            if provider == .thisMac {
                if case .ready = engine.state { result = .ok("Ready") }
                else { result = .unreachable("Not downloaded yet. Download it in Settings › AI") }
            } else {
                result = await AIClient.shared.check(provider, key: provider.isLocal ? nil : AIKeys.key(for: provider))
            }
            switch result {
            case .ok(let what): checks[provider] = .connected(what)
            case .noKey: checks[provider] = .noKey
            case .refused: checks[provider] = .refused
            case .unreachable(let why):
                checks[provider] = .down(provider == .ollama && !why.contains("Start") ? "Ollama isn't running. Start Ollama" : why)
            }
        }
    }

    private func refreshHints() {
        var found: [AIProvider: String] = [:]
        for provider in Self.cloud { if let hint = AIKeys.hint(for: provider) { found[provider] = hint } }
        hints = found
    }

    private func refresh() {
        refreshHints()
        for provider in [AIProvider.ollama, .lmStudio, .thisMac] { test(provider) }
        Task { await models.refresh() }
    }

    // MARK: roles

    private func entries(for role: ModelRole) -> [ModelStore.Entry] {
        role.localOnly ? models.local : models.all
    }

    private func roleRow(_ role: ModelRole) -> some View {
        let binding = Binding<ModelChoice?>(
            get: { router.configured(role) },
            set: { router.set($0, for: role) })
        let list = entries(for: role)
        return Line(role.title, role.detail) {
            Picker("", selection: binding) {
                if role != .chat { Text("Same as Chat").tag(ModelChoice?.none) }
                else if binding.wrappedValue == nil { Text("Choose…").tag(ModelChoice?.none) }
                if let now = binding.wrappedValue, !list.contains(where: { $0.choice == now }) {
                    Text(now.label).tag(ModelChoice?.some(now))
                }
                ForEach(list) { entry in
                    Text("\(entry.title) · \(entry.detail)").tag(ModelChoice?.some(entry.choice))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("\(role.title) model")
        }
    }

    // MARK: Ollama

    private var ollamaCard: some View {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return Card {
            Line("Recommended for this Mac",
                 "\(catalog.recommendedName) for \(ramGB) GB of memory. Downloaded by Ollama, then runs on this Mac") {
                if catalog.hasRecommended {
                    Label("Installed", systemImage: "checkmark").font(Theme.small).foregroundStyle(Theme.textMuted)
                } else {
                    Pill("Pull", filled: true) { catalog.startPull(catalog.recommendedName) }
                }
            }
            if let pull = catalog.pull {
                Rule()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pull.failed == nil ? "Pulling \(pull.name)" : "Couldn't pull \(pull.name)")
                            .font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Spacer()
                        if pull.failed == nil { Pill("Cancel") { catalog.cancelPull() } }
                        else { Pill("Dismiss") { catalog.dismissFailure() } }
                    }
                    if let failed = pull.failed {
                        Text(failed).font(Theme.small).foregroundStyle(Theme.textMuted)
                    } else {
                        ProgressView(value: pull.total > 0 ? pull.fraction : nil)
                            .progressViewStyle(.linear)
                        Text(pull.total > 0 ? "\(pull.status) · \(Int(pull.fraction * 100))%" : pull.status)
                            .font(Theme.small).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
            Rule()
            Line("Another model", "Any name from ollama.com/library, such as nomic-embed-text") {
                HStack(spacing: 6) {
                    TextField("", text: $custom, prompt: Text("name:tag").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit { catalog.startPull(custom); custom = "" }
                    Pill("Pull") { catalog.startPull(custom); custom = "" }
                }
            }
            Rule()
            if !catalog.asked || catalog.installed.isEmpty {
                Line("Installed", catalog.reachable ? "Ollama has no model yet. Pull one above"
                                                    : "Ollama isn't running. Start Ollama, then look again") {
                    Pill("Look Again") { Task { await catalog.refresh(); await models.refresh() } }
                }
            } else {
                ForEach(Array(catalog.installed.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Rule() }
                    HStack(spacing: 8) {
                        Text(model.name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                        if model.running {
                            Text("in memory").font(Theme.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer(minLength: 8)
                        Label("\(model.sizeText) · \(model.fit.words)", systemImage: model.fit.symbol)
                            .font(Theme.small).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
