import AVFoundation
import Foundation
import Speech

/// Uses Apple's on-device Speech and Dictation APIs with a graceful fallback.
actor LocalSpeechTranscriber {
    func prepareModel(localeIdentifier: String) async throws {
        #if targetEnvironment(simulator)
        throw LocalSpeechError.simulatorUnsupported
        #else
        do {
            _ = try await makeSpeechTranscriber(
                localeIdentifier: localeIdentifier
            )
        } catch {
            _ = try await makeDictationTranscriber(
                localeIdentifier: localeIdentifier
            )
        }
        #endif
    }

    func transcribe(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> [TranscriptSegment] {
        #if targetEnvironment(simulator)
        throw LocalSpeechError.simulatorUnsupported
        #else
        let requestedLocale = Locale(identifier: localeIdentifier)
        if SpeechTranscriber.isAvailable,
           await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) != nil {
            do {
                return try await transcribeWithSpeech(
                    fileURL: fileURL,
                    localeIdentifier: localeIdentifier
                )
            } catch {
                // Dictation assets may already be present when the higher-quality
                // general transcription model cannot be downloaded.
            }
        }

        return try await transcribeWithDictation(
            fileURL: fileURL,
            localeIdentifier: localeIdentifier
        )
        #endif
    }

    private func transcribeWithSpeech(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> [TranscriptSegment] {
        let transcriber = try await makeSpeechTranscriber(
            localeIdentifier: localeIdentifier
        )

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw LocalSpeechError.audioFileUnavailable(
                error.localizedDescription
            )
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let pendingSegments = collectResults(from: transcriber)

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)

            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw LocalSpeechError.analysisFailed(error.localizedDescription)
        }

        let segments = try await pendingSegments
        guard !segments.isEmpty else {
            throw LocalSpeechError.emptyTranscript
        }
        return segments
    }

    private func makeSpeechTranscriber(
        localeIdentifier: String
    ) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw LocalSpeechError.unsupportedDevice
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw LocalSpeechError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus != .unsupported else {
            throw LocalSpeechError.unsupportedLocale(localeIdentifier)
        }

        do {
            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await installationRequest.downloadAndInstall()
            }
        } catch {
            throw LocalSpeechError.modelUnavailable(error.localizedDescription)
        }

        return transcriber
    }

    private func transcribeWithDictation(
        fileURL: URL,
        localeIdentifier: String
    ) async throws -> [TranscriptSegment] {
        let transcriber = try await makeDictationTranscriber(
            localeIdentifier: localeIdentifier
        )

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw LocalSpeechError.audioFileUnavailable(
                error.localizedDescription
            )
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let pendingSegments = collectDictationResults(from: transcriber)

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)

            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw LocalSpeechError.analysisFailed(error.localizedDescription)
        }

        let segments = try await pendingSegments
        guard !segments.isEmpty else {
            throw LocalSpeechError.emptyTranscript
        }
        return segments
    }

    private func makeDictationTranscriber(
        localeIdentifier: String
    ) async throws -> DictationTranscriber {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            throw LocalSpeechError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            preset: .timeIndexedLongDictation
        )

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus != .unsupported else {
            throw LocalSpeechError.unsupportedLocale(localeIdentifier)
        }

        do {
            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await installationRequest.downloadAndInstall()
            }
        } catch {
            throw LocalSpeechError.modelUnavailable(error.localizedDescription)
        }

        return transcriber
    }

    private func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let start = max(0, result.range.start.seconds)
            let end = max(start + 0.2, result.range.end.seconds)

            segments.append(
                TranscriptSegment(
                    start: start,
                    end: end,
                    text: text
                )
            )
        }

        return segments
    }

    private func collectDictationResults(
        from transcriber: DictationTranscriber
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for try await result in transcriber.results {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let start = max(0, result.range.start.seconds)
            let end = max(start + 0.2, result.range.end.seconds)

            segments.append(
                TranscriptSegment(
                    start: start,
                    end: end,
                    text: text
                )
            )
        }

        return segments
    }
}

// MARK: - Errors

enum LocalSpeechError: LocalizedError {
    case simulatorUnsupported
    case unsupportedDevice
    case unsupportedLocale(String)
    case modelUnavailable(String)
    case audioFileUnavailable(String)
    case analysisFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        let language = InterfaceLanguage.current

        switch self {
        case .simulatorUnsupported:
            return language.text("speech.error.simulatorUnsupported")
        case .unsupportedDevice:
            return language.text("speech.error.unsupportedDevice")
        case .unsupportedLocale(let identifier):
            return language.format("speech.error.unsupportedLocale", identifier)
        case .modelUnavailable(let detail):
            return language.format("speech.error.modelUnavailable", detail)
        case .audioFileUnavailable(let detail):
            return language.format("speech.error.audioFileUnavailable", detail)
        case .analysisFailed(let detail):
            return language.format("speech.error.analysisFailed", detail)
        case .emptyTranscript:
            return language.text("speech.error.emptyTranscript")
        }
    }
}
