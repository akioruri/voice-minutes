import SwiftUI

/// Glass floating record control pinned above the bottom of the meeting list.
/// Idle it is a circular blue Liquid Glass button; tapping morphs it into a
/// solid red glass capsule: the mic symbol replaces into a stop glyph and
/// slides right while the elapsed time slides in from the left, so the timer
/// stays visible without occupying the toolbar.
struct RecordFloatingButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isRecording: Bool
    let duration: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // A ZStack keeps the symbol's view identity stable across states
            // so the replace effect plays, and animates its alignment from
            // center to trailing: the icon visibly slides right to make room
            // while the time materialises in place on the left.
            ZStack {
                if isRecording {
                    Text(MeetingRowView.formatDuration(duration))
                        .font(.body.monospacedDigit())
                        .contentTransition(.numericText())
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity, alignment: isRecording ? .trailing : .center)
            }
            .foregroundStyle(.white)
            .frame(width: isRecording ? 68 : 54, height: 54)
            .padding(.horizontal, isRecording ? 18 : 0)
            // A capsule over the square idle frame renders as a circle, so one
            // shape covers both states: blue glass circle when idle, solid red
            // glass capsule while recording.
            .glassEffect(
                isRecording
                    ? .regular.tint(.red).interactive()
                    : .regular.tint(.blue).interactive(),
                in: .capsule
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(
            reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.24),
            value: isRecording
        )
        .accessibilityLabel(
            InterfaceLanguage.current.text(
                isRecording ? "recording.stop" : "recording.start"
            )
        )
        .accessibilityValue(
            isRecording ? MeetingRowView.formatDuration(duration) : ""
        )
    }
}
