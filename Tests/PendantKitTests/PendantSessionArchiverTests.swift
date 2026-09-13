import Foundation
import XCTest
@testable import PendantKit

final class PendantSessionArchiverTests: XCTestCase {
    func testArchivesConcatenatedEligibleOpusBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = manifest([[Data([1, 2])], [Data([3])]])

        let archive = try PendantSessionArchiver(rootURL: root).archive(session, sessionID: "session-1")

        XCTAssertEqual(try Data(contentsOf: archive.opusURL), Data([1, 2, 3]))
    }

    func testRefusesSessionWithoutEligibleOpus() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = manifest([[]])

        XCTAssertThrowsError(try PendantSessionArchiver(rootURL: root).archive(session, sessionID: "empty")) { error in
            guard case .emptyEligibleOpus = error as? PendantSessionArchiveError else {
                return XCTFail("Expected empty eligible Opus error")
            }
        }
    }

    private func manifest(_ groups: [[Data]]) -> PendantSessionManifest {
        let contributions = groups.enumerated().map { offset, bytes in
            PendantSessionPageContribution(
                identity: PendantPageIdentity(
                    deviceID: "device", sessionID: "session", runID: "run",
                    sequence: offset, pageIndex: offset
                ),
                timestamp: UInt64(offset),
                encodedOpusBytes: bytes
            )
        }
        return PendantSessionManifest(index: 0, contributions: contributions, openingBoundary: nil, closingBoundary: nil)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendantSessionArchiverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
