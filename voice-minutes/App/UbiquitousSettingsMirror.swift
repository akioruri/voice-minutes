import Foundation

/// Mirrors a fixed set of settings keys through NSUbiquitousKeyValueStore so
/// preferences follow the user across devices. Device-local keys (the sync
/// master switch, window state) are deliberately excluded.
///
/// Without the ubiquity entitlement the store is inert: `synchronize()`
/// returns false and no values or notifications arrive, so the app keeps
/// working with local settings only.
@MainActor
final class UbiquitousSettingsMirror {
    /// Keys that participate in cross-device settings sync. API keys are NOT
    /// settings keys and never enter this store — they stay in the Keychain.
    static let mirroredKeys: Set<String> = {
        var keys: Set<String> = [
            InterfaceLanguage.storageKey,
            "provider.transcription",
            "provider.summary",
            "transcription.useAppleLocal",
            "transcription.localLocale",
            "minutes.promptTemplate",
            "minutes.promptLibrary",
            "minutes.defaultPromptID",
            "analysis.keyPointPromptTemplate",
            "analysis.markPromptTemplate",
            "analysis.autoAnalyzeMarks",
            "sync.audioEnabled"
        ]
        for provider in AIProvider.allCases {
            let prefix = "provider.\(provider.rawValue)"
            keys.insert("\(prefix).baseURL")
            keys.insert("\(prefix).transcriptionModel")
            keys.insert("\(prefix).summaryModel")
        }
        return keys
    }()

    /// Called on the main actor with the mirrored keys that changed remotely.
    var onRemoteChange: (([String]) -> Void)?

    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    func start() {
        store.synchronize()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                let changed = notification.userInfo?[
                    NSUbiquitousKeyValueStoreChangedKeysKey
                ] as? [String] ?? []
                let mirrored = changed.filter { Self.mirroredKeys.contains($0) }
                if !mirrored.isEmpty {
                    self.onRemoteChange?(mirrored)
                }
            }
        }
    }

    func object(forKey key: String) -> Any? {
        store.object(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        guard Self.mirroredKeys.contains(key) else {
            return
        }
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
