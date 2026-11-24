import Foundation
import Observation

@Observable
final class AppSettings {
    /// Localized built-in templates (user-visible, follow the interface
    /// language). Internal LLM scaffolding stays English in CloudAIService.
    static var defaultPrompt: String {
        InterfaceLanguage.current.text("prompt.builtin.minutes")
    }

    static var defaultKeyPointPrompt: String {
        InterfaceLanguage.current.text("prompt.builtin.keyPoint")
    }

    static var defaultMarkPrompt: String {
        InterfaceLanguage.current.text("prompt.builtin.mark")
    }

    private let defaults = UserDefaults.standard
    private let legacyKeychainService = "voice-minutes.mistral"
    private let mirror = UbiquitousSettingsMirror()
    /// Guards against echoing remotely-applied values back to iCloud.
    private var isApplyingMirror = false

    // MARK: - Persisted settings

    var interfaceLanguage: InterfaceLanguage {
        didSet {
            persistSetting(interfaceLanguage.rawValue, forKey: Keys.interfaceLanguage)
        }
    }

    var transcriptionProvider: AIProvider {
        didSet {
            persistSetting(transcriptionProvider.rawValue, forKey: Keys.transcriptionProvider)
        }
    }

    var summaryProvider: AIProvider {
        didSet {
            persistSetting(summaryProvider.rawValue, forKey: Keys.summaryProvider)
        }
    }

    var useLocalTranscription: Bool {
        didSet {
            persistSetting(useLocalTranscription, forKey: Keys.useLocalTranscription)
        }
    }

    var localTranscriptionLocaleIdentifier: String {
        didSet {
            persistSetting(
                localTranscriptionLocaleIdentifier,
                forKey: Keys.localTranscriptionLocale
            )
        }
    }

    /// Named minutes-prompt library, persisted as JSON and mirrored.
    var minutesPrompts: [MinutesPrompt] {
        didSet {
            persistLibrary()
        }
    }

    /// Global default selection; nil means the localized built-in template.
    var defaultMinutesPromptID: UUID? {
        didSet {
            // Empty string = explicit built-in choice; a missing key means
            // "never set" and seeds the first library entry on launch.
            persistSetting(
                defaultMinutesPromptID?.uuidString ?? "",
                forKey: Keys.defaultMinutesPromptID
            )
            persistLegacyPrompt()
        }
    }

    /// The resolved global-default minutes prompt body (library → built-in).
    var promptTemplate: String {
        resolvedDefaultPromptBody()
    }

    /// Editable system prompt for per-block key-point analysis.
    var keyPointPromptTemplate: String {
        didSet {
            let prompt = keyPointPromptTemplate
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                return
            }
            persistSetting(prompt, forKey: Keys.keyPointPromptTemplate)
        }
    }

    /// Editable system prompt for time-mark analysis (transcript window
    /// around the mark).
    var markPromptTemplate: String {
        didSet {
            let prompt = markPromptTemplate
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                return
            }
            persistSetting(prompt, forKey: Keys.markPromptTemplate)
        }
    }

    /// When on, marks are summarized automatically once the transcript is
    /// ready. Mirrored across devices.
    var autoAnalyzeMarks: Bool {
        didSet {
            persistSetting(autoAnalyzeMarks, forKey: Keys.autoAnalyzeMarks)
        }
    }

    /// Device-local master switch for iCloud sync. Never mirrored, so every
    /// device opts in explicitly and an upgrade never uploads silently.
    var syncEnabled: Bool {
        didSet {
            defaults.set(syncEnabled, forKey: Keys.syncEnabled)
        }
    }

    /// Whether recordings upload alongside meetings. Mirrored across devices.
    var syncAudioEnabled: Bool {
        didSet {
            persistSetting(syncAudioEnabled, forKey: Keys.syncAudioEnabled)
        }
    }

    private var providerConfigurations: [AIProvider: ProviderConfiguration]

    /// Set when a settings change could not be written to the Keychain, so the
    /// settings window can report it next to the field that caused it.
    var lastPersistenceError: String?

    // MARK: - Lifecycle

    init() {
        interfaceLanguage = InterfaceLanguage(
            rawValue: defaults.string(forKey: Keys.interfaceLanguage) ?? ""
        ) ?? InterfaceLanguage.preferredForSystem
        transcriptionProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.transcriptionProvider) ?? ""
        ) ?? .mistral
        summaryProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.summaryProvider) ?? ""
        ) ?? .mistral
        useLocalTranscription = defaults.object(
            forKey: Keys.useLocalTranscription
        ) as? Bool ?? false
        localTranscriptionLocaleIdentifier = defaults.string(
            forKey: Keys.localTranscriptionLocale
        ) ?? "zh-CN"
        let library: [MinutesPrompt]
        if let json = defaults.string(forKey: Keys.promptLibrary),
           let decoded = try? JSONDecoder().decode(
               [MinutesPrompt].self,
               from: Data(json.utf8)
           ) {
            library = decoded
        } else {
            // Migrate the legacy single prompt into a named library entry.
            let legacy = defaults.string(forKey: Keys.promptTemplate)
                ?? defaults.string(forKey: Keys.legacyPromptTemplate)
                ?? ""
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            let builtIn = Self.defaultPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            library = (trimmed.isEmpty || trimmed == builtIn)
                ? []
                : [MinutesPrompt(
                    name: InterfaceLanguage.current.text("settings.customPromptName"),
                    body: legacy
                  )]
        }
        minutesPrompts = library
        let initialDefaultID: UUID?
        if let idString = defaults.string(forKey: Keys.defaultMinutesPromptID) {
            initialDefaultID = idString.isEmpty ? nil : UUID(uuidString: idString)
        } else {
            initialDefaultID = library.first?.id
        }
        defaultMinutesPromptID = initialDefaultID
        keyPointPromptTemplate = defaults.string(forKey: Keys.keyPointPromptTemplate)
            ?? Self.defaultKeyPointPrompt
        markPromptTemplate = defaults.string(forKey: Keys.markPromptTemplate)
            ?? Self.defaultMarkPrompt
        autoAnalyzeMarks = defaults.object(forKey: Keys.autoAnalyzeMarks) as? Bool ?? true
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? false
        syncAudioEnabled = defaults.object(forKey: Keys.syncAudioEnabled) as? Bool ?? true

        var configurations: [AIProvider: ProviderConfiguration] = [:]
        for provider in AIProvider.allCases {
            var configuration = provider.defaultConfiguration
            let prefix = "provider.\(provider.rawValue)"

            if provider == .mistral {
                configuration.baseURL = defaults.string(forKey: "\(prefix).baseURL")
                    ?? defaults.string(forKey: Keys.legacyBaseURL)
                    ?? configuration.baseURL
                configuration.transcriptionModel = defaults.string(forKey: "\(prefix).transcriptionModel")
                    ?? defaults.string(forKey: Keys.legacyTranscriptionModel)
                    ?? configuration.transcriptionModel
                configuration.summaryModel = defaults.string(forKey: "\(prefix).summaryModel")
                    ?? defaults.string(forKey: Keys.legacySummaryModel)
                    ?? configuration.summaryModel
            } else {
                configuration.baseURL = defaults.string(forKey: "\(prefix).baseURL")
                    ?? configuration.baseURL
                configuration.transcriptionModel = defaults.string(forKey: "\(prefix).transcriptionModel")
                    ?? configuration.transcriptionModel
                configuration.summaryModel = defaults.string(forKey: "\(prefix).summaryModel")
                    ?? configuration.summaryModel
            }

            configuration.apiKey = APIKeyStore.read(
                service: Self.keychainService(for: provider),
                account: "api-key"
            ) ?? (provider == .mistral
                ? APIKeyStore.read(service: legacyKeychainService, account: "api-key")
                : nil)
            ?? ""

            configurations[provider] = configuration
        }
        providerConfigurations = configurations
        // init assignments bypass didSet, so persist the selection explicitly
        // before the mirror reconcile reloads properties from defaults.
        defaults.set(initialDefaultID?.uuidString ?? "", forKey: Keys.defaultMinutesPromptID)
        persistLibrary()
        reconcileWithMirror()
    }

    var transcriptionConfiguration: ProviderConfiguration {
        configuration(for: transcriptionProvider)
    }

    var summaryConfiguration: ProviderConfiguration {
        configuration(for: summaryProvider)
    }

    var transcriptionBaseURL: String {
        get { configuration(for: transcriptionProvider).baseURL }
        set {
            updateConfiguration(for: transcriptionProvider) {
                $0.baseURL = newValue
            }
        }
    }

    var transcriptionModel: String {
        get { configuration(for: transcriptionProvider).transcriptionModel }
        set {
            updateConfiguration(for: transcriptionProvider) {
                $0.transcriptionModel = newValue
            }
        }
    }

    var transcriptionAPIKey: String {
        get { configuration(for: transcriptionProvider).apiKey }
        set {
            updateConfiguration(for: transcriptionProvider) {
                $0.apiKey = newValue
            }
        }
    }

    var summaryBaseURL: String {
        get { configuration(for: summaryProvider).baseURL }
        set {
            updateConfiguration(for: summaryProvider) {
                $0.baseURL = newValue
            }
        }
    }

    var summaryModel: String {
        get { configuration(for: summaryProvider).summaryModel }
        set {
            updateConfiguration(for: summaryProvider) {
                $0.summaryModel = newValue
            }
        }
    }

    var summaryAPIKey: String {
        get { configuration(for: summaryProvider).apiKey }
        set {
            updateConfiguration(for: summaryProvider) {
                $0.apiKey = newValue
            }
        }
    }

    var isTranscriptionConfigured: Bool {
        if useLocalTranscription {
            return !localTranscriptionLocaleIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        return isConfigurationComplete(transcriptionConfiguration)
    }

    var isSummaryConfigured: Bool {
        isConfigurationComplete(summaryConfiguration)
    }

    var isConfigured: Bool {
        isTranscriptionConfigured && isSummaryConfigured
    }

    func configuration(for provider: AIProvider) -> ProviderConfiguration {
        providerConfigurations[provider] ?? provider.defaultConfiguration
    }

    // MARK: - Persistence

    private func updateConfiguration(
        for provider: AIProvider,
        update: (inout ProviderConfiguration) -> Void
    ) {
        var configuration = configuration(for: provider)
        update(&configuration)
        providerConfigurations[provider] = configuration
        try? persist(configuration, for: provider)
    }

    private func persist(
        _ configuration: ProviderConfiguration,
        for provider: AIProvider
    ) throws {
        let prefix = "provider.\(provider.rawValue)"
        storeDefault(configuration.baseURL, forKey: "\(prefix).baseURL")
        storeDefault(
            configuration.transcriptionModel,
            forKey: "\(prefix).transcriptionModel"
        )
        storeDefault(configuration.summaryModel, forKey: "\(prefix).summaryModel")

        do {
            try APIKeyStore.save(
                configuration.apiKey,
                service: Self.keychainService(for: provider),
                account: "api-key"
            )
            // Only touch the error when it actually changes, so an ordinary
            // keystroke never publishes an update from inside a view update.
            if lastPersistenceError != nil {
                lastPersistenceError = nil
            }
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    private func isConfigurationComplete(_ configuration: ProviderConfiguration) -> Bool {
        !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.transcriptionModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.summaryModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func keychainService(for provider: AIProvider) -> String {
        "voice-minutes.provider.\(provider.rawValue)"
    }

    private func storeDefault(_ value: String, forKey key: String) {
        if value.isEmpty {
            defaults.removeObject(forKey: key)
            if !isApplyingMirror {
                mirror.set(nil, forKey: key)
            }
        } else {
            defaults.set(value, forKey: key)
            if !isApplyingMirror {
                mirror.set(value, forKey: key)
            }
        }
    }

    // MARK: - Minutes prompt library

    func resolvedDefaultPromptBody() -> String {
        MinutesPromptResolver.body(
            folderPromptID: nil,
            defaultPromptID: defaultMinutesPromptID,
            library: minutesPrompts,
            builtIn: Self.defaultPrompt
        )
    }

    @discardableResult
    func addMinutesPrompt(name: String, body: String) -> UUID {
        let unique = MinutesPromptResolver.uniqueName(
            name,
            in: minutesPrompts,
            fallback: InterfaceLanguage.current.text("settings.untitledPrompt")
        )
        let prompt = MinutesPrompt(name: unique, body: body)
        minutesPrompts.append(prompt)
        return prompt.id
    }

    /// Renames a prompt, auto-suffixing to keep names unique. Returns the
    /// final name so the editor can sync its draft.
    @discardableResult
    func renameMinutesPrompt(_ id: UUID, to name: String) -> String {
        guard let index = minutesPrompts.firstIndex(where: { $0.id == id }) else {
            return name
        }
        let unique = MinutesPromptResolver.uniqueName(
            name,
            in: minutesPrompts,
            excluding: id,
            fallback: InterfaceLanguage.current.text("settings.untitledPrompt")
        )
        minutesPrompts[index].name = unique
        return unique
    }

    func updateMinutesPrompt(_ id: UUID, body: String) {
        guard let index = minutesPrompts.firstIndex(where: { $0.id == id }) else {
            return
        }
        minutesPrompts[index].body = body
    }

    func deleteMinutesPrompt(_ id: UUID) {
        minutesPrompts.removeAll { $0.id == id }
        if defaultMinutesPromptID == id {
            defaultMinutesPromptID = nil
        }
    }

    private func persistLibrary() {
        if let data = try? JSONEncoder().encode(minutesPrompts),
           let json = String(data: data, encoding: .utf8) {
            persistSetting(json, forKey: Keys.promptLibrary)
        }
        persistLegacyPrompt()
    }

    /// Keeps the legacy single-prompt key equal to the resolved global default
    /// so older app versions still read a sensible template.
    private func persistLegacyPrompt() {
        let body = resolvedDefaultPromptBody()
        defaults.set(body, forKey: Keys.promptTemplate)
        if !isApplyingMirror {
            mirror.set(body, forKey: Keys.promptTemplate)
        }
    }

    // MARK: - iCloud settings mirror

    /// Writes a mirrored setting locally and to iCloud. Remote-applied values
    /// are written locally only, so they never echo back.
    private func persistSetting(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        if !isApplyingMirror {
            mirror.set(value, forKey: key)
        }
    }

    /// On launch: remote values win where they exist; local-only values seed
    /// iCloud. Then reload the observable properties from the merged defaults.
    private func reconcileWithMirror() {
        isApplyingMirror = true
        for key in UbiquitousSettingsMirror.mirroredKeys {
            if let remoteValue = mirror.object(forKey: key) {
                defaults.set(remoteValue, forKey: key)
            } else if let localValue = defaults.object(forKey: key) {
                mirror.set(localValue, forKey: key)
            }
        }
        reloadMirroredProperties()
        isApplyingMirror = false

        mirror.onRemoteChange = { [weak self] keys in
            self?.applyMirrorChanges(keys)
        }
        mirror.start()
    }

    private func applyMirrorChanges(_ keys: [String]) {
        isApplyingMirror = true
        for key in keys {
            if let value = mirror.object(forKey: key) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        reloadMirroredProperties()
        isApplyingMirror = false
    }

    /// Re-reads mirrored values from UserDefaults into the observable
    /// properties. API keys are preserved: they never leave the Keychain.
    private func reloadMirroredProperties() {
        interfaceLanguage = InterfaceLanguage(
            rawValue: defaults.string(forKey: Keys.interfaceLanguage) ?? ""
        ) ?? InterfaceLanguage.preferredForSystem
        transcriptionProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.transcriptionProvider) ?? ""
        ) ?? .mistral
        summaryProvider = AIProvider(
            rawValue: defaults.string(forKey: Keys.summaryProvider) ?? ""
        ) ?? .mistral
        useLocalTranscription = defaults.object(
            forKey: Keys.useLocalTranscription
        ) as? Bool ?? false
        localTranscriptionLocaleIdentifier = defaults.string(
            forKey: Keys.localTranscriptionLocale
        ) ?? "zh-CN"
        if let json = defaults.string(forKey: Keys.promptLibrary),
           let library = try? JSONDecoder().decode(
               [MinutesPrompt].self,
               from: Data(json.utf8)
           ) {
            minutesPrompts = library
        } else {
            minutesPrompts = []
        }
        defaultMinutesPromptID = defaults.string(forKey: Keys.defaultMinutesPromptID)
            .flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        keyPointPromptTemplate = defaults.string(forKey: Keys.keyPointPromptTemplate)
            ?? Self.defaultKeyPointPrompt
        markPromptTemplate = defaults.string(forKey: Keys.markPromptTemplate)
            ?? Self.defaultMarkPrompt
        autoAnalyzeMarks = defaults.object(forKey: Keys.autoAnalyzeMarks) as? Bool ?? true
        syncAudioEnabled = defaults.object(forKey: Keys.syncAudioEnabled) as? Bool ?? true

        for provider in AIProvider.allCases {
            let prefix = "provider.\(provider.rawValue)"
            var configuration = providerConfigurations[provider]
                ?? provider.defaultConfiguration
            configuration.baseURL = defaults.string(forKey: "\(prefix).baseURL")
                ?? configuration.baseURL
            configuration.transcriptionModel = defaults.string(
                forKey: "\(prefix).transcriptionModel"
            ) ?? configuration.transcriptionModel
            configuration.summaryModel = defaults.string(forKey: "\(prefix).summaryModel")
                ?? configuration.summaryModel
            providerConfigurations[provider] = configuration
        }
    }

    private enum Keys {
        static let interfaceLanguage = InterfaceLanguage.storageKey
        static let transcriptionProvider = "provider.transcription"
        static let summaryProvider = "provider.summary"
        static let useLocalTranscription = "transcription.useAppleLocal"
        static let localTranscriptionLocale = "transcription.localLocale"
        static let promptTemplate = "minutes.promptTemplate"
        static let promptLibrary = "minutes.promptLibrary"
        static let defaultMinutesPromptID = "minutes.defaultPromptID"
        static let keyPointPromptTemplate = "analysis.keyPointPromptTemplate"
        static let markPromptTemplate = "analysis.markPromptTemplate"
        static let autoAnalyzeMarks = "analysis.autoAnalyzeMarks"
        static let syncEnabled = "sync.enabled"
        static let syncAudioEnabled = "sync.audioEnabled"
        static let legacyPromptTemplate = "mistral.promptTemplate"
        static let legacyBaseURL = "mistral.baseURL"
        static let legacyTranscriptionModel = "mistral.transcriptionModel"
        static let legacySummaryModel = "mistral.summaryModel"
    }
}

enum SettingsError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        let language = InterfaceLanguage.current

        switch self {
        case .keychain(let status):
            return language.format("settings.error.keychain", status)
        }
    }
}
