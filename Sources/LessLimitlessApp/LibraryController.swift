import Combine
import Domain
import Foundation
import PendantKit

@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var recordings: [LibraryRecording] = []
    @Published private(set) var searchResults: [LibrarySearchResult] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeRecordingID: UUID?
    @Published private(set) var transcribingID: UUID?
    private var isProcessingQueue = false

    private let rootURL: URL
    private let store: LocalLibraryStore?

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LessLimitless", isDirectory: true)
        rootURL = root
        do { store = try LocalLibraryStore(rootURL: root) }
        catch { store = nil; errorMessage = "Could not open the local library" }
    }

    func reload() async {
        guard let store else { return }
        recordings = await store.recordings()
    }

    func search(_ query: String) async {
        guard let store else { return }
        searchResults = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : await store.search(query)
    }

    func save(_ recording: LibraryRecording) async {
        guard let store else { return }
        var updated = recording
        updated.updatedAt = Date()
        do {
            try await store.upsert(updated)
            await reload()
        } catch {
            errorMessage = "Could not save the recording"
        }
    }

    func delete(_ recording: LibraryRecording) async {
        guard let store else { return }
        do {
            try await store.delete(id: recording.id)
            await reload()
        } catch {
            errorMessage = "Could not delete the recording"
        }
    }

    func mediaURL(for recording: LibraryRecording) async -> URL? {
        guard let store else { return nil }
        return try? await store.mediaURL(for: recording)
    }

    /// Decodes any pendant pages sitting in the raw vault into playable WAV sessions
    /// and registers ones not already in the library. Safe to call repeatedly:
    /// sessions already present (matched by their derived archive path) are skipped.
    @discardableResult
    func syncPendant(deviceName: String) async -> Int {
        guard let store else { return 0 }
        let vaultRootURL = rootURL.appendingPathComponent("RawPageVault", isDirectory: true)
        let wavRootURL = rootURL.appendingPathComponent("PendantAudio", isDirectory: true)
        let report: PendantLibrarySyncReport
        do {
            report = try await Task.detached(priority: .utility) {
                let pipeline = try PendantVaultSessionPipeline(vaultRootURL: vaultRootURL)
                return try pipeline.exportToLibrary(wavRootURL: wavRootURL)
            }.value
        } catch {
            errorMessage = "Could not sync pendant pages to the library"
            return 0
        }

        let existingPaths = Set(recordings.compactMap(\.mediaRelativePath))
        var importedCount = 0
        for session in report.exportedSessions {
            let relative = "PendantAudio/\(session.archiveID).wav.export/audio.wav"
            guard !existingPaths.contains(relative) else { continue }
            let started = session.earliestTimestampMilliseconds.flatMap { Self.plausibleDate(fromMilliseconds: $0) } ?? Date()
            let ended = session.latestTimestampMilliseconds.flatMap { Self.plausibleDate(fromMilliseconds: $0) }
            let recording = LibraryRecording(
                title: "Pendant recording",
                source: .pendant(deviceName: deviceName),
                mediaRelativePath: relative,
                startedAt: started,
                endedAt: ended,
                processingState: .captured
            )
            do {
                try await store.create(recording)
                importedCount += 1
            } catch {
                errorMessage = "Could not register a pendant recording in the library"
            }
        }
        // One encounter failing to decode must not hide that the rest of the sync
        // succeeded, but it also must not be silently dropped.
        if !report.failedExports.isEmpty {
            errorMessage = "\(report.failedExports.count) pendant recording(s) could not be decoded and were skipped"
        }
        if importedCount > 0 { await reload() }
        return importedCount
    }

    func registerCapture(directory: URL, request: MacAudioCaptureRequest) async {
        guard let store else { return }
        let standardized = directory.standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
        guard standardized.path.hasPrefix(rootPath) else {
            errorMessage = "Capture was outside the local library root"
            return
        }
        let source: RecordingSource
        switch request.source {
        case .systemAudio: source = .systemAudio
        case .application(let application): source = .macApplication(name: application.name)
        }
        do {
            let asset = try await CaptureFinalizer.finalize(directory: standardized)
            let relative = String(asset.standardizedFileURL.path.dropFirst(rootPath.count))
            let recording = LibraryRecording(
                title: captureTitle(for: request),
                source: source,
                mediaRelativePath: relative,
                startedAt: Date(),
                endedAt: Date(),
                processingState: .captured,
                tags: ["Mac Capture"]
            )
            try await store.create(recording)
            await reload()
        } catch {
            errorMessage = "Could not finalize captured audio for the library"
        }
    }

    func transcribe(_ recording: LibraryRecording, job: LocalTranscriptionJob) async {
        guard let store, let mediaURL = await mediaURL(for: recording), !mediaURL.hasDirectoryPath else {
            errorMessage = "Transcription requires a single local audio file"
            return
        }
        var processing = recording
        processing.processingState = .processing
        processing.updatedAt = Date()
        do { try await store.upsert(processing); await reload() }
        catch { errorMessage = "Could not queue transcription"; return }

        let configuredJob = LocalTranscriptionJob(
            executableURL: job.executableURL,
            audioURL: mediaURL,
            arguments: job.arguments.map { $0 == job.audioURL.path ? mediaURL.path : $0 },
            timeout: job.timeout,
            maximumOutputBytes: job.maximumOutputBytes,
            expectsTimestampedJSON: job.expectsTimestampedJSON
        )
        do {
            let result = try await Task.detached(priority: .utility) {
                try LocalTranscriptionEngine().transcribe(configuredJob)
            }.value
            var completed = processing
            completed.transcriptSegments = result.segments
            completed.processingState = .ready
            completed.updatedAt = Date()
            try await store.upsert(completed)
            await reload()
        } catch {
            var failed = processing
            failed.processingState = .failed
            failed.updatedAt = Date()
            try? await store.upsert(failed)
            errorMessage = "Transcription failed"
            await reload()
        }
    }

    func generateSummary(_ recording: LibraryRecording, configuration: OptionalLLMConfiguration) async {
        guard let store else { return }
        let transcript = recording.transcriptSegments.map(\.text).joined(separator: " ")
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Transcribe this recording before generating a summary"
            return
        }
        do {
            let result = try await OptionalLLMProvider().generate(
                LLMGenerationRequest(transcript: transcript, instruction: "Summarize the transcript. Include decisions and action items when present."),
                configuration: configuration
            )
            let disposition = result.processedRemotely ? "sent to \(result.providerHost)" : "stayed on device"
            var updated = recording
            updated.generatedArtifacts.append(LibraryGeneratedArtifact(kind: "summary (\(result.model)) · \(disposition)", text: result.text))
            updated.updatedAt = Date()
            try await store.upsert(updated)
            await reload()
        } catch {
            errorMessage = "Summary generation failed"
        }
    }

    /// Transcribes (and optionally summarizes) every `.captured` recording serially,
    /// so a sync that imports several encounters doesn't spawn N concurrent whisper
    /// processes. Safe to call repeatedly: `transcribe(_:job:)` moves a record out of
    /// `.captured` before this loop would revisit it, and a second concurrent call is
    /// blocked by `isProcessingQueue`.
    func processPendingTranscriptions(job: LocalTranscriptionJob?, summaryConfiguration: OptionalLLMConfiguration?) async {
        guard let job, !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false; transcribingID = nil }

        while let next = recordings.first(where: { $0.processingState == .captured && $0.mediaRelativePath != nil }) {
            transcribingID = next.id
            await transcribe(next, job: job)
            if let summaryConfiguration, let updated = recordings.first(where: { $0.id == next.id }), updated.processingState == .ready {
                await generateSummary(updated, configuration: summaryConfiguration)
            }
        }
    }

    /// Pendant clocks read ~0 for pages recorded before the device was ever paired/synced.
    /// Treat anything before 2020 as an unset clock rather than showing a decades-old date.
    private static func plausibleDate(fromMilliseconds ms: UInt64) -> Date? {
        let date = Date(timeIntervalSince1970: Double(ms) / 1_000)
        return date > Date(timeIntervalSince1970: 1_577_836_800) ? date : nil
    }

    private func captureTitle(for request: MacAudioCaptureRequest) -> String {
        switch request.source {
        case .systemAudio: "Mac audio capture"
        case .application(let application): "\(application.name) capture"
        }
    }
}
