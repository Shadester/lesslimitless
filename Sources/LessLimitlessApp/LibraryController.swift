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

    func registerCapture(directory: URL, request: MacAudioCaptureRequest) async {
        guard let store else { return }
        let standardized = directory.standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
        guard standardized.path.hasPrefix(rootPath) else {
            errorMessage = "Capture was outside the local library root"
            return
        }
        let relative = String(standardized.path.dropFirst(rootPath.count))
        let source: RecordingSource
        switch request.source {
        case .systemAudio: source = .systemAudio
        case .application(let application): source = .macApplication(name: application.name)
        }
        let recording = LibraryRecording(
            title: captureTitle(for: request),
            source: source,
            mediaRelativePath: relative,
            startedAt: Date(),
            endedAt: Date(),
            processingState: .captured,
            tags: ["Mac Capture"]
        )
        do {
            try await store.create(recording)
            await reload()
        } catch {
            errorMessage = "Could not add captured audio to the library"
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
            var updated = recording
            updated.generatedArtifacts.append(LibraryGeneratedArtifact(kind: "summary (\(result.model))", text: result.text))
            updated.updatedAt = Date()
            try await store.upsert(updated)
            await reload()
        } catch {
            errorMessage = "Summary generation failed"
        }
    }

    private func captureTitle(for request: MacAudioCaptureRequest) -> String {
        switch request.source {
        case .systemAudio: "Mac audio capture"
        case .application(let application): "\(application.name) capture"
        }
    }
}
