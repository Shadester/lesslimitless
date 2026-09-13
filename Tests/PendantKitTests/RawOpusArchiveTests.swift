import Foundation
import XCTest
@testable import PendantKit

final class RawOpusArchiveTests: XCTestCase {
    func testWritesRawOpusAndCodableManifestInCallerRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([0x4f, 0x70, 0x75, 0x73])

        let archive = try RawOpusArchiveWriter(rootURL: root).write(opusData: payload, sessionID: "session_01")

        XCTAssertEqual(
            archive.opusURL.deletingLastPathComponent(),
            root.appendingPathComponent("session_01.archive", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(archive.opusURL.pathExtension, "raw")
        XCTAssertEqual(try Data(contentsOf: archive.opusURL), payload)
        let manifest = try JSONDecoder().decode(RawOpusArchiveManifest.self, from: Data(contentsOf: archive.manifestURL))
        XCTAssertEqual(manifest.sessionID, "session_01")
        XCTAssertEqual(manifest.byteCount, payload.count)
        XCTAssertEqual(manifest.opusSHA256, RawOpusArchiveWriter.sha256Hex(payload))
    }

    func testIdenticalWriteIsIdempotentAndReloadsFromDisk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("assembled opus bytes".utf8)
        let writer = try RawOpusArchiveWriter(rootURL: root)

        let first = try writer.write(opusData: payload, sessionID: "session")
        let second = try writer.write(opusData: payload, sessionID: "session")

        XCTAssertEqual(second, first)
        XCTAssertEqual(try RawOpusArchiveWriter(rootURL: root).write(opusData: payload, sessionID: "session"), first)
    }

    func testDifferentContentForSameSessionCollides() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try RawOpusArchiveWriter(rootURL: root)
        _ = try writer.write(opusData: Data([1]), sessionID: "session")

        XCTAssertThrowsError(try writer.write(opusData: Data([2]), sessionID: "session")) { error in
            guard case .collision(let sessionID, _, _) = error as? RawOpusArchiveError else {
                return XCTFail("Expected collision, got \(error)")
            }
            XCTAssertEqual(sessionID, "session")
        }
    }

    func testTraversalSessionIDCannotEscapeCallerRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try RawOpusArchiveWriter(rootURL: root)

        XCTAssertThrowsError(try writer.write(opusData: Data([1]), sessionID: "../outside")) { error in
            XCTAssertEqual(error as? RawOpusArchiveError, .unsafeSessionID("../outside"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside.opus.raw").path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawOpusArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
