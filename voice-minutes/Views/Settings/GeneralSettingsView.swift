import SwiftUI

/// General settings pane: interface language and iCloud sync.
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CloudSyncController.self) private var sync

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker(
                    "settings.interfaceLanguage",
                    selection: $settings.interfaceLanguage
                ) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(verbatim: language.displayName)
                            .tag(language)
                    }
                }
            } footer: {
                Text("settings.interfaceLanguageFooter")
            }

            Section {
                Toggle(isOn: $settings.syncEnabled) {
                    Label("sync.enable", systemImage: "icloud")
                }

                Toggle(isOn: $settings.syncAudioEnabled) {
                    Label("sync.audio", systemImage: "waveform")
                }
                .disabled(!settings.syncEnabled)

                syncStatusRow

                if let lastSyncDate = sync.lastSyncDate {
                    Text(
                        InterfaceLanguage.current.format(
                            "sync.lastSync",
                            lastSyncDate.formatted(
                                .dateTime.month().day().hour().minute()
                            )
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Label("sync.title", systemImage: "icloud")
                    .symbolRenderingMode(.hierarchical)
            } footer: {
                Text("sync.footer")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(InterfaceLanguage.current.text("settings.generalTitle"))
    }

    private var syncStatusRow: some View {
        let language = InterfaceLanguage.current
        return Group {
            switch sync.status {
            case .disabled:
                Label(language.text("sync.status.disabled"), systemImage: "icloud.slash")
            case .unavailable:
                Label(
                    language.text("sync.status.unavailable"),
                    systemImage: "exclamationmark.icloud"
                )
            case .noAccount:
                Label(
                    language.text("sync.status.noAccount"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            case .idle:
                Label(language.text("sync.status.synced"), systemImage: "checkmark.icloud")
            case .syncing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("sync.status.syncing"))
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            }

            if let detail = sync.statusDetail {
                Text(verbatim: detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    let store = MeetingStore()
    let settings = AppSettings()
    GeneralSettingsView()
        .environment(settings)
        .environment(CloudSyncController(store: store, settings: settings))
        .frame(width: 640, height: 620)
}
