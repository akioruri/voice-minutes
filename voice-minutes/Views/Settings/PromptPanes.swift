import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Fixed seven-line height for prompt editors, derived from the body
/// monospaced font so it tracks the platform text size.
func promptEditorHeight() -> CGFloat {
    #if os(macOS)
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    #else
    let size = UIFont.preferredFont(forTextStyle: .body).pointSize
    let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let lineHeight = font.lineHeight
    #endif
    return lineHeight * 7 + 16
}

/// Edits a single minutes prompt: name (auto-deduped on commit), body,
/// global-default toggle, and inline AI generation of title + body. Deletion
/// lives in the prompt list (swipe / context menu), not here.
struct PromptEditorView: View {
    let promptID: UUID

    @Environment(AppSettings.self) private var settings
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var aiDescription = ""
    @State private var isGenerating = false
    @State private var aiError: String?

    private var prompt: MinutesPrompt? {
        settings.minutesPrompts.first { $0.id == promptID }
    }

    var body: some View {
        Form {
            if let prompt {
                Section {
                    TextField("settings.promptName", text: $nameDraft)
                        .focused($nameFocused)
                        .onSubmit { commitName() }

                    TextEditor(text: Binding(
                        get: { prompt.body },
                        set: { settings.updateMinutesPrompt(prompt.id, body: $0) }
                    ))
                    .font(.body.monospaced())
                    .frame(height: promptEditorHeight())

                    Toggle("settings.setAsGlobalDefault", isOn: Binding(
                        get: { settings.defaultMinutesPromptID == promptID },
                        set: { settings.defaultMinutesPromptID = $0 ? promptID : nil }
                    ))
                }

                Section {
                    TextField(
                        "settings.aiDescriptionPlaceholder",
                        text: $aiDescription,
                        prompt: Text(verbatim: InterfaceLanguage.current.text(
                            "settings.aiDescriptionPlaceholder"
                        ))
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)

                    Button {
                        generateWithAI()
                    } label: {
                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("settings.aiGenerating")
                            }
                        } else {
                            Label("settings.aiGeneratePrompt", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isGenerating
                            || aiDescription
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !settings.isSummaryConfigured
                    )

                    if !settings.isSummaryConfigured {
                        Label("settings.aiNeedsSummary", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let aiError {
                        Label(aiError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } header: {
                    Label("settings.aiGeneratePrompt", systemImage: "wand.and.stars")
                        .symbolRenderingMode(.hierarchical)
                } footer: {
                    Text("settings.aiGenerateFooter")
                }
            } else {
                ContentUnavailableView(
                    "settings.promptMissing",
                    systemImage: "text.quote"
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(prompt?.name ?? InterfaceLanguage.current.text("settings.promptsTitle"))
        .onAppear {
            nameDraft = prompt?.name ?? ""
        }
        .onChange(of: promptID) { _, _ in
            nameDraft = prompt?.name ?? ""
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused {
                commitName()
            }
        }
    }

    private func commitName() {
        guard let prompt else {
            return
        }
        nameDraft = settings.renameMinutesPrompt(prompt.id, to: nameDraft)
    }

    /// Generates a title + body from the description and writes them back to
    /// the current prompt. The base is the current body, or the built-in
    /// template when the body is empty.
    private func generateWithAI() {
        guard let prompt else {
            return
        }
        let description = aiDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, settings.isSummaryConfigured else {
            return
        }
        isGenerating = true
        aiError = nil
        let base = prompt.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettings.defaultPrompt
            : prompt.body
        let service = CloudAIService(
            provider: settings.summaryProvider,
            configuration: settings.summaryConfiguration
        )
        Task {
            do {
                let result = try await service.generatePrompt(
                    description: description,
                    baseTemplate: base
                )
                settings.updateMinutesPrompt(prompt.id, body: result.body)
                if !result.name.isEmpty {
                    nameDraft = settings.renameMinutesPrompt(prompt.id, to: result.name)
                }
                aiDescription = ""
            } catch {
                aiError = error.localizedDescription
            }
            isGenerating = false
        }
    }
}

/// The two analysis prompts: key-point explanation and time-mark summary.
struct AnalysisPromptsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                TextEditor(text: $settings.keyPointPromptTemplate)
                    .font(.body.monospaced())
                    .frame(height: promptEditorHeight())

                Button {
                    settings.keyPointPromptTemplate = AppSettings.defaultKeyPointPrompt
                } label: {
                    Label(
                        "settings.restoreDefaultKeyPointPrompt",
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(.borderless)
            } header: {
                Label("settings.keyPointPromptSection", systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
            }

            Section {
                Toggle(isOn: $settings.autoAnalyzeMarks) {
                    Label("settings.autoAnalyzeMarks", systemImage: "bookmark")
                }

                TextEditor(text: $settings.markPromptTemplate)
                    .font(.body.monospaced())
                    .frame(height: promptEditorHeight())

                Button {
                    settings.markPromptTemplate = AppSettings.defaultMarkPrompt
                } label: {
                    Label(
                        "settings.restoreDefaultMarkPrompt",
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(.borderless)
            } header: {
                Label("settings.markPromptSection", systemImage: "bookmark")
                    .symbolRenderingMode(.hierarchical)
            } footer: {
                Text("settings.analysisPromptFooter")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(InterfaceLanguage.current.text("settings.analysisTitle"))
    }
}
