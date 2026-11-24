import Foundation

/// Serializes ordered transcript segments as SubRip text.
enum SRTBuilder {
    static func make(from segments: [TranscriptSegment]) -> String {
        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        var output: [String] = []
        var previousEnd: TimeInterval = 0

        for (index, segment) in ordered.enumerated() {
            // Keep cues monotonic because providers may return slightly overlapping times.
            let start = max(previousEnd, max(0, segment.start))
            let end = max(start + 0.2, segment.end)
            let text = segment.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            output.append(String(index + 1))
            output.append("\(timestamp(start)) --> \(timestamp(end))")
            output.append(text)
            output.append("")
            previousEnd = end
        }

        return output.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1_000).rounded())
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let secondsPart = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        return String(
            format: "%02d:%02d:%02d,%03d",
            hours,
            minutes,
            secondsPart,
            milliseconds
        )
    }

    /// Transcript text around a time point: cues overlapping the window
    /// [time - radius, time + radius]. Falls back to the full transcript
    /// when the window catches nothing.
    static func windowText(
        from srt: String,
        around time: TimeInterval,
        radius: TimeInterval = 120
    ) -> String {
        let all = cues(from: srt)
        let window = all.filter { $0.start <= time + radius && $0.end >= time - radius }
        let source = window.isEmpty ? all : window
        return source.map(\.text).joined(separator: "\n")
    }

    // MARK: - Cue parsing

    /// Splits SubRip text into the individual cues used for playback highlighting.
    static func cues(from srt: String) -> [TranscriptCue] {
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [TranscriptCue] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard lines.count >= 2,
                  let timeRange = parseTimeRange(lines[1]) else {
                continue
            }

            let text = lines.dropFirst(2).joined(separator: "\n")
            guard !text.isEmpty else {
                continue
            }

            cues.append(
                TranscriptCue(
                    start: timeRange.start,
                    end: timeRange.end,
                    text: text
                )
            )
        }

        return cues.sorted { $0.start < $1.start }
    }

    private static func parseTimeRange(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1]) else {
            return nil
        }
        return (start, end)
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        let components = cleaned.components(separatedBy: ":")
        guard components.count == 3 else {
            return nil
        }

        guard let hours = Double(components[0]),
              let minutes = Double(components[1]) else {
            return nil
        }

        // Seconds are written as "ss,mmm" in SubRip.
        let secondsPart = components[2].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart) else {
            return nil
        }

        return hours * 3_600 + minutes * 60 + seconds
    }
}

/// A single timestamped line of the transcript, shown with playback highlighting.
struct TranscriptCue: Identifiable, Hashable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    /// Compact "mm:ss" label used beside the cue text.
    var timeLabel: String {
        let totalSeconds = Int(max(0, start).rounded())
        return String(
            format: "%02d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}

/// A time-anchored overlay row in the transcript: an unconverted recording
/// mark (`isMark`) or a key-note block that inherited a mark's anchor.
/// View-only: never written into exported SRT.
struct TranscriptMarker: Identifiable, Hashable, Sendable {
    let id: UUID
    let time: TimeInterval
    let text: String
    let isMark: Bool
}
