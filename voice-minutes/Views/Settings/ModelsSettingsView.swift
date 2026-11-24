import SwiftUI

/// Models pane: AI configuration for both transcription and meeting-minutes
/// summary, grouped into two sections.
struct ModelsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var isPreparingLocalModel = false
    @State private var localModelStatus: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(isOn: $settings.useLocalTranscription) {
                    Label(
                        "settings.useAppleLocalTranscription",
                        systemImage: "waveform"
                    )
                }

                if settings.useLocalTranscription {
                    TextField(
                        "settings.recognitionLanguageCode",
                        text: $settings.localTranscriptionLocaleIdentifier,
                        prompt: Text("zh-CN")
                    )

                    SettingsNote("settings.localRecognitionDescription")

                    Button {
                        prepareLocalModel()
                    } label: {
                        Label(
                            "settings.checkAndDownloadLocalModel",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(isPreparingLocalModel)

                    if isPreparingLocalModel {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(
                                localModelStatus
                                    ?? InterfaceLanguage.current.text(
                                        "settings.downloadingLocalModel"
                                    )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let localModelStatus {
                        Label(localModelStatus, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                } else {
                    Picker("settings.provider", selection: $settings.transcriptionProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    TextField(
                        "settings.apiURL",
                        text: Binding(
                            get: { settings.transcriptionBaseURL },
                            set: { settings.transcriptionBaseURL = $0 }
                        ),
                        prompt: Text("https://api.example.com/v1")
                    )

                    TextField(
                        "settings.transcriptionModel",
                        text: Binding(
                            get: { settings.transcriptionModel },
                            set: { settings.transcriptionModel = $0 }
                        )
                    )

                    SecureField(
                        InterfaceLanguage.current.text("settings.apiKey"),
                        text: Binding(
                            get: { settings.transcriptionAPIKey },
                            set: { settings.transcriptionAPIKey = $0 }
                        )
                    )

                    if settings.transcriptionProvider == .miniMax {
                        SettingsNote("settings.miniMaxDescription")
                    } else {
                        SettingsNote("settings.segmentDescription")
                    }
                }
            } header: {
                Label("settings.voiceRecognition", systemImage: "waveform")
                    .symbolRenderingMode(.hierarchical)
            }

            Section {
                Picker("settings.provider", selection: $settings.summaryProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                TextField(
                    "settings.apiURL",
                    text: Binding(
                        get: { settings.summaryBaseURL },
                        set: { settings.summaryBaseURL = $0 }
                    ),
                    prompt: Text("https://api.example.com/v1")
                )

                TextField(
                    "settings.summaryModel",
                    text: Binding(
                        get: { settings.summaryModel },
                        set: { settings.summaryModel = $0 }
                    )
                )

                SecureField(
                    InterfaceLanguage.current.text("settings.apiKey"),
                    text: Binding(
                        get: { settings.summaryAPIKey },
                        set: { settings.summaryAPIKey = $0 }
                    )
                )

                SettingsNote("settings.providerNote")

                if let errorMessage = settings.lastPersistenceError {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Label("settings.meetingMinutes", systemImage: "doc.text")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(InterfaceLanguage.current.text("settings.modelsTitle"))
    }

    private func prepareLocalModel() {
        let localeIdentifier = settings.localTranscriptionLocaleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localeIdentifier.isEmpty else {
            localModelStatus = InterfaceLanguage.current.text(
                "settings.enterRecognitionLanguage"
            )
            return
        }

        isPreparingLocalModel = true
        localModelStatus = InterfaceLanguage.current.text(
            "settings.checkingAppleSpeechResources"
        )

        Task {
            do {
                try await LocalSpeechTranscriber().prepareModel(
                    localeIdentifier: localeIdentifier
                )
                localModelStatus = InterfaceLanguage.current.text(
                    "settings.localModelReady"
                )
            } catch {
                localModelStatus = error.localizedDescription
            }
            isPreparingLocalModel = false
        }
    }
}
