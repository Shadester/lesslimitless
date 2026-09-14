import Foundation
import XCTest
@testable import PendantKit
import Domain

final class LocalLibraryStoreTests: XCTestCase {
    func testPersistsAndReloadsRecording() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = LibraryRecording(title: "Planning", source: .imported, mediaRelativePath: "media/plan.wav", startedAt: timestamp, createdAt: timestamp, updatedAt: timestamp, notes: "Keep this")
        let store = try LocalLibraryStore(rootURL: root)
        try await store.create(recording)

        let reloaded = try LocalLibraryStore(rootURL: root)
        let restored = await reloaded.recording(id: recording.id)
        XCTAssertEqual(restored, recording)
    }

    func testUnicodeSearchAndRankingIncludesMatchFields() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalLibraryStore(rootURL: root)
        let title = LibraryRecording(title: "Café review", source: .imported)
        let transcript = LibraryRecording(
            title: "Other", source: .imported,
            transcriptSegments: [TranscriptSegment(startTime: 0, endTime: 1, text: "The cafe review is complete")]
        )
        try await store.upsert(transcript)
        try await store.upsert(title)

        let results = await store.search("CAFE review")
        XCTAssertEqual(results.map(\.recording.id), [title.id, transcript.id])
        XCTAssertEqual(results.first?.matchedFields, [.title])
        XCTAssertTrue(results[1].matchedFields.contains(.transcript))
    }

    func testDeleteRemovesOwnedMediaAndRejectsTraversal() async throws {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let media = root.appendingPathComponent("media/audio.wav")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: media)
        try Data([2]).write(to: outside)
        let store = try LocalLibraryStore(rootURL: root)
        let recording = LibraryRecording(title: "Owned", source: .imported, mediaRelativePath: "media/audio.wav")
        try await store.upsert(recording)
        try await store.delete(id: recording.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        let unsafe = LibraryRecording(title: "Unsafe", source: .imported, mediaRelativePath: "../\(outside.lastPathComponent)")
        await XCTAssertThrowsErrorAsync(try await store.upsert(unsafe)) { error in
            XCTAssertEqual(error as? LocalLibraryStoreError, .invalidMediaRelativePath("../\(outside.lastPathComponent)"))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLibraryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
