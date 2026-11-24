import SwiftUI

/// Settings entry point. macOS lists the minutes prompts directly in the
/// sidebar; iOS uses a drill-in list with the same panes. Top-level
/// categories are General, Models, and Analysis.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        MacSettingsLayout()
        #else
        IOSSettingsMenu()
        #endif
    }
}

/// The fixed top-level categories (prompts expands into a list of individual
/// prompts rather than a single pane).
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case models
    case analysis
    case prompts

    var id: Self { self }

    var title: String {
        let language = InterfaceLanguage.current
        switch self {
        case .general:
            return language.text("settings.generalTitle")
        case .models:
            return language.text("settings.modelsTitle")
        case .analysis:
            return language.text("settings.analysisTitle")
        case .prompts:
            return language.text("settings.promptsTitle")
        }
    }

    var symbol: String {
        switch self {
        case .general:
            return "gearshape"
        case .models:
            return "cpu"
        case .analysis:
            return "sparkles"
        case .prompts:
            return "text.quote"
        }
    }
}

// MARK: - macOS sidebar layout

#if os(macOS)
/// Sidebar selection: a fixed category or a specific prompt.
private enum SettingsSelection: Hashable {
    case general
    case models
    case analysis
    case prompt(UUID)
}

private struct MacSettingsLayout: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: SettingsSelection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    sidebarCategory(.general)
                    sidebarCategory(.models)
                    sidebarCategory(.analysis)
                }

                Section {
                    ForEach(settings.minutesPrompts) { prompt in
                        HStack {
                            Label(prompt.name, systemImage: "text.quote")
                            Spacer()
                            if settings.defaultMinutesPromptID == prompt.id {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(SettingsSelection.prompt(prompt.id))
                        .contextMenu {
                            Button(role: .destructive) {
                                deletePrompt(prompt.id)
                            } label: {
                                Label("common.delete", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        let id = settings.addMinutesPrompt(
                            name: InterfaceLanguage.current.text("settings.untitledPrompt"),
                            body: AppSettings.defaultPrompt
                        )
                        selection = .prompt(id)
                    } label: {
                        Label("settings.addPrompt", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("settings.promptsTitle")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView()
            case .models:
                ModelsSettingsView()
            case .analysis:
                AnalysisPromptsView()
            case .prompt(let id):
                PromptEditorView(promptID: id)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func sidebarCategory(_ category: SettingsCategory) -> some View {
        Label(category.title, systemImage: category.symbol)
            .symbolRenderingMode(.hierarchical)
            .tag(selection(for: category))
    }

    private func selection(for category: SettingsCategory) -> SettingsSelection {
        switch category {
        case .general:
            return .general
        case .models:
            return .models
        case .analysis:
            return .analysis
        case .prompts:
            return .analysis
        }
    }

    private func deletePrompt(_ id: UUID) {
        settings.deleteMinutesPrompt(id)
        if selection == .prompt(id) {
            selection = .general
        }
    }
}
#endif

// MARK: - iOS drill-in list

#if os(iOS)
/// Unified navigation routes for the iOS settings stack.
private enum SettingsRoute: Hashable {
    case general
    case models
    case analysis
    case prompts
    case promptEditor(UUID)
}

private struct IOSSettingsMenu: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    ForEach(SettingsCategory.allCases) { category in
                        NavigationLink(value: route(for: category)) {
                            Label(category.title, systemImage: category.symbol)
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(InterfaceLanguage.current.text("settings.navigationTitle"))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .general:
                    GeneralSettingsView()
                case .models:
                    ModelsSettingsView()
                case .analysis:
                    AnalysisPromptsView()
                case .prompts:
                    PromptsListView(path: $path)
                case .promptEditor(let id):
                    PromptEditorView(promptID: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(InterfaceLanguage.current.text("common.done")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func route(for category: SettingsCategory) -> SettingsRoute {
        switch category {
        case .general:
            return .general
        case .models:
            return .models
        case .analysis:
            return .analysis
        case .prompts:
            return .prompts
        }
    }
}

/// The prompts list on iOS: one row per prompt (swipe to delete) plus a new
/// prompt button at the end.
private struct PromptsListView: View {
    @Binding var path: [SettingsRoute]
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Section {
                ForEach(settings.minutesPrompts) { prompt in
                    NavigationLink(value: SettingsRoute.promptEditor(prompt.id)) {
                        HStack {
                            Label(prompt.name, systemImage: "text.quote")
                            Spacer()
                            if settings.defaultMinutesPromptID == prompt.id {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            settings.deleteMinutesPrompt(prompt.id)
                        } label: {
                            Label("common.delete", systemImage: "trash")
                        }
                    }
                }

                Button {
                    let id = settings.addMinutesPrompt(
                        name: InterfaceLanguage.current.text("settings.untitledPrompt"),
                        body: AppSettings.defaultPrompt
                    )
                    path.append(.promptEditor(id))
                } label: {
                    Label("settings.addPrompt", systemImage: "plus")
                }
            }
        }
        .navigationTitle(InterfaceLanguage.current.text("settings.promptsTitle"))
    }
}
#endif

/// Small informational note used across the settings panes.
struct SettingsNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    let store = MeetingStore()
    let settings = AppSettings()
    SettingsView()
        .environment(settings)
        .environment(CloudSyncController(store: store, settings: settings))
}
