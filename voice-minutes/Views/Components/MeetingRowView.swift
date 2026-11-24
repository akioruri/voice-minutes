import SwiftUI

struct MeetingRowView: View {
    @Environment(MeetingStore.self) private var store

    let meeting: MeetingRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                        .lineLimit(1)

                    if meeting.isDeleted {
                        Label("library.recentlyDeleted", systemImage: "trash")
                            .lineLimit(1)
                    } else if let folder = folderName {
                        Label(folder, systemImage: "folder")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(secondaryTextColor)
            }

            Spacer()

            if meeting.duration > 0 {
                Text(Self.formatDuration(meeting.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondaryTextColor)
            }
        }
        .padding(.vertical, 5)
        // Pin the system separator's edges: its default insets are re-measured
        // from row content (a folder Label shortened the line, scroll changed
        // it again). Fixed guides keep every line identical.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 40 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
        .accessibilityElement(children: .combine)
    }

    private var isSelected: Bool {
        store.selectedMeetingID == meeting.id
    }

    /// The inset list style draws the accent-filled selection highlight itself,
    /// so row text switches to the system's selected-surface color rather than
    /// to a hard-coded white.
    private var titleColor: Color {
        isSelected ? SelectedRowText.color : .primary
    }

    private var secondaryTextColor: Color {
        isSelected ? SelectedRowText.color : .secondary
    }

    private var folderName: String? {
        guard let folderID = meeting.folderID else {
            return nil
        }
        return store.folders.first { $0.id == folderID }?.name
    }

    private var statusIcon: String {
        switch meeting.status {
        case .pending:
            return "clock"
        case .processing:
            return "waveform"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch meeting.status {
        case .pending:
            return .secondary
        case .processing:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
