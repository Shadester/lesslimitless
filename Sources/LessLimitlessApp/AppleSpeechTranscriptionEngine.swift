import AVFoundation
import Domain
import Foundation
import Speech

/// On-device transcription via Apple's Speech framework — an alternative to
/// whisper.cpp with no bundled model/subprocess, and none of whisper.cpp's own
/// VAD crash risk. Tradeoff: word-level output (regrouped into sentence-ish
/// segments below) rather than whisper's native sentence segmentation.
///
/// `SFSpeechURLRecognitionRequest` isn't built for long-form audio: fed an
/// entire pendant recording (minutes long) it reliably fails with "No speech
/// detected" rather than transcribing the parts that do have speech. Chunking
/// into short windows and recognizing each independently works around that;
/// a chunk that really is silent just fails on its own and is skipped.
enum AppleSpeechTranscriptionError: Error, Equatable {
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case recognitionFailed(String)
}

struct AppleSpeechTranscriptionEngine {
    private static let chunkDuration: TimeInterval = 55

    func transcribe(audioURL: URL) async throws -> LocalTranscriptionResult {
        try await Self.requestAuthorization()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw AppleSpeechTranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechTranscriptionError.onDeviceRecognitionUnavailable
        }

        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let framesPerChunk = AVAudioFramePosition(Self.chunkDuration * sampleRate)

        var allSegments: [TranscriptSegment] = []
        var allText: [String] = []
        var chunkStart: AVAudioFramePosition = 0
        while chunkStart < totalFrames {
            let framesToRead = min(framesPerChunk, totalFrames - chunkStart)
            let chunkURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            try Self.writeChunk(of: file, startFrame: chunkStart, frameCount: framesToRead, to: chunkURL)

            let offset = TimeInterval(chunkStart) / sampleRate
            do {
                let transcription = try await Self.recognize(chunkURL, recognizer: recognizer)
                allText.append(transcription.formattedString)
                allSegments += Self.groupIntoSegments(transcription.segments).map { $0.offset(by: offset) }
            } catch AppleSpeechTranscriptionError.recognitionFailed {
                // A chunk with no detectable speech (silence, noise-floor only)
                // is expected on this hardware — skip it, don't fail the whole recording.
            }
            chunkStart += framesToRead
        }

        guard !allText.isEmpty || !allSegments.isEmpty else {
            throw AppleSpeechTranscriptionError.recognitionFailed("No speech detected")
        }

        return LocalTranscriptionResult(
            text: allText.joined(separator: " "),
            segments: allSegments.collapsingHallucinatedRepeats(),
            language: "en",
            provenance: LocalTranscriptionProvenance(
                executableURL: audioURL,
                audioURL: audioURL,
                arguments: ["SFSpeechRecognizer", "requiresOnDeviceRecognition"],
                exitStatus: 0,
                stdoutWasTruncated: false,
                stderrWasTruncated: false
            )
        )
    }

    private static func writeChunk(of file: AVAudioFile, startFrame: AVAudioFramePosition, frameCount: AVAudioFramePosition, to url: URL) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw AppleSpeechTranscriptionError.recognitionFailed("Could not allocate audio buffer")
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        let outFile = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings)
        try outFile.write(from: buffer)
    }

    private static func recognize(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> SFTranscription {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTranscription, Error>) in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: AppleSpeechTranscriptionError.recognitionFailed(error.localizedDescription))
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription)
                }
            }
        }
    }

    private static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw AppleSpeechTranscriptionError.authorizationDenied }
    }

    /// Apple returns one SFTranscriptionSegment per word. Group consecutive words
    /// into sentence-ish chunks on long pauses, the same "long gap = boundary"
    /// idea whisper uses, so the UI's tap-to-seek rows stay at sentence grain.
    private static func groupIntoSegments(_ words: [SFTranscriptionSegment], pauseThreshold: TimeInterval = 0.8) -> [TranscriptSegment] {
        guard let first = words.first else { return [] }
        var segments: [TranscriptSegment] = []
        var chunk: [SFTranscriptionSegment] = [first]
        for word in words.dropFirst() {
            let previousEnd = chunk[chunk.count - 1].timestamp + chunk[chunk.count - 1].duration
            if word.timestamp - previousEnd > pauseThreshold {
                segments.append(segment(from: chunk))
                chunk = []
            }
            chunk.append(word)
        }
        if !chunk.isEmpty { segments.append(segment(from: chunk)) }
        return segments
    }

    private static func segment(from words: [SFTranscriptionSegment]) -> TranscriptSegment {
        TranscriptSegment(
            startTime: words[0].timestamp,
            endTime: words[words.count - 1].timestamp + words[words.count - 1].duration,
            text: words.map(\.substring).joined(separator: " ")
        )
    }
}

private extension TranscriptSegment {
    func offset(by seconds: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(startTime: startTime + seconds, endTime: endTime + seconds, text: text, speaker: speaker)
    }
}
