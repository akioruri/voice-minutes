import Accelerate
import AVFoundation
import Foundation

/// Splits long recordings near quiet passages before sending chunks to cloud ASR.
actor AudioChunker {
    private let silenceSearchRadius: TimeInterval = 20
    private let minSilenceDuration: TimeInterval = 0.3
    private let levelWindowDuration: TimeInterval = 0.05

    func split(
        sourceURL: URL,
        outputDirectory: URL,
        targetChunkDuration: TimeInterval = 15 * 60
    ) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !audioTracks.isEmpty else {
            throw AudioChunkError.noAudioTrack
        }

        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AudioChunkError.invalidDuration
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let boundaries = try planBoundaries(
            sourceURL: sourceURL,
            duration: duration,
            targetChunkDuration: targetChunkDuration
        )
        var chunks: [AudioChunk] = []

        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let outputURL = outputDirectory.appendingPathComponent(
                String(format: "chunk-%03d.m4a", index + 1)
            )

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            guard let exporter = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw AudioChunkError.cannotCreateExporter
            }

            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 44_100),
                end: CMTime(seconds: end, preferredTimescale: 44_100)
            )

            try await exporter.export(to: outputURL, as: .m4a)

            chunks.append(
                AudioChunk(
                    index: index,
                    fileURL: outputURL,
                    originalStart: start,
                    duration: end - start
                )
            )
        }

        return chunks
    }

    private func planBoundaries(
        sourceURL: URL,
        duration: TimeInterval,
        targetChunkDuration: TimeInterval
    ) throws -> [TimeInterval] {
        guard duration > targetChunkDuration + 60 else {
            return [0, duration]
        }

        let audioFile = try AVAudioFile(forReading: sourceURL)
        var boundaries: [TimeInterval] = [0]
        var target = targetChunkDuration

        while target < duration - 60 {
            let boundary = findSilenceBoundary(
                audioFile: audioFile,
                target: target,
                duration: duration
            )
            boundaries.append(boundary)
            target = boundary + targetChunkDuration
        }

        boundaries.append(duration)
        return boundaries
    }

    private func findSilenceBoundary(
        audioFile: AVAudioFile,
        target: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let searchStart = max(0, target - silenceSearchRadius)
        let searchEnd = min(duration, target + silenceSearchRadius)

        guard let levels = audioLevels(
            audioFile: audioFile,
            start: searchStart,
            end: searchEnd
        ), levels.count > 2 else {
            return target
        }

        let sortedLevels = levels.map(\.dbfs).sorted()
        // Adapt the silence threshold to the local noise floor so quiet rooms
        // still produce useful cut points.
        let noiseIndex = max(0, Int(Double(sortedLevels.count) * 0.1) - 1)
        let noiseFloor = sortedLevels[noiseIndex]
        let threshold = min(noiseFloor + 8, Float(-30))

        var silentRuns: [ClosedRange<TimeInterval>] = []
        var runStart: TimeInterval?

        for level in levels {
            if level.dbfs <= threshold {
                if runStart == nil {
                    runStart = level.time
                }
            } else if let start = runStart {
                if level.time - start >= minSilenceDuration {
                    silentRuns.append(start...level.time)
                }
                runStart = nil
            }
        }

        if let start = runStart,
           let last = levels.last,
           last.time + levelWindowDuration - start >= minSilenceDuration {
            silentRuns.append(start...(last.time + levelWindowDuration))
        }

        return silentRuns
            .map { ($0.lowerBound + $0.upperBound) / 2 }
            .min { abs($0 - target) < abs($1 - target) }
            ?? target
    }

    private func audioLevels(
        audioFile: AVAudioFile,
        start: TimeInterval,
        end: TimeInterval
    ) -> [(time: TimeInterval, dbfs: Float)]? {
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)

        guard sampleRate > 0, channelCount > 0 else {
            return nil
        }

        let framesPerWindow = AVAudioFrameCount(
            max(1, Int(sampleRate * levelWindowDuration))
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: framesPerWindow
        ) else {
            return nil
        }

        let startFrame = AVAudioFramePosition((start * sampleRate).rounded())
        let endFrame = AVAudioFramePosition((end * sampleRate).rounded())
        audioFile.framePosition = startFrame

        var levels: [(time: TimeInterval, dbfs: Float)] = []

        while audioFile.framePosition < endFrame {
            let remaining = endFrame - audioFile.framePosition
            let requestedFrames = AVAudioFrameCount(
                min(Int64(framesPerWindow), remaining)
            )

            guard requestedFrames > 0 else {
                break
            }

            do {
                try audioFile.read(into: buffer, frameCount: requestedFrames)
            } catch {
                return levels.isEmpty ? nil : levels
            }

            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channels = buffer.floatChannelData else {
                break
            }

            let windowStart = Double(
                audioFile.framePosition - AVAudioFramePosition(frameCount)
            ) / sampleRate

            var totalEnergy: Float = 0
            for channel in 0..<channelCount {
                var channelEnergy: Float = 0
                vDSP_svesq(
                    channels[channel],
                    1,
                    &channelEnergy,
                    vDSP_Length(frameCount)
                )
                totalEnergy += channelEnergy
            }

            let rms = sqrt(totalEnergy / Float(frameCount * channelCount))
            let dbfs = 20 * log10f(max(rms, Float(1e-7)))
            levels.append((windowStart, dbfs))
        }

        return levels
    }
}

// MARK: - Errors

enum AudioChunkError: LocalizedError {
    case noAudioTrack
    case invalidDuration
    case cannotCreateExporter

    var errorDescription: String? {
        let language = InterfaceLanguage.current

        switch self {
        case .noAudioTrack:
            return language.text("audio.error.noAudioTrack")
        case .invalidDuration:
            return language.text("audio.error.invalidDuration")
        case .cannotCreateExporter:
            return language.text("audio.error.cannotCreateExporter")
        }
    }
}
