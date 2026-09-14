import Domain
import Combine
import Foundation
import PendantKit

@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var recordings: [LibraryRecording] = []
    @Published private(set) var searchResults: [LibrarySearchResult] = []
    @Published private(set) var errorMessage: String?

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

    private func captureTitle(for request: MacAudioCaptureRequest) -> String {
        switch request.source {
        case .systemAudio: "Mac audio capture"
        case .application(let application): "\(application.name) capture"
        }
    }
}
