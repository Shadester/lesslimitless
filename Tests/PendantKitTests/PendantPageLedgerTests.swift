import Foundation
import XCTest
@testable import PendantKit

final class PendantPageLedgerTests: XCTestCase {
    func testIngestPersistsRawPageAndReloadsLedger() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = pageIdentity()
        let payload = Data("raw pendant page".utf8)

        let ledger = try PendantPageLedger(rootURL: root)
        let result = try ledger.ingest(payload, for: identity, receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case .stored(let record) = result else { return XCTFail("Expected initial storage") }
        XCTAssertEqual(record.rawPageHash, "d858298ca1a42cbd6262468712a1c4e3c93e845f0f95c8f4e4a0e34bd025cf39")
        XCTAssertEqual(record.state, .received)
        XCTAssertEqual(try Data(contentsOf: ledger.rawPageURL(for: identity)), payload)

        let reloaded = try PendantPageLedger(rootURL: root)
        XCTAssertEqual(reloaded.record(for: identity), record)
        XCTAssertEqual(reloaded.records.count, 1)
    }

    func testIdenticalIngestIsIdempotentAndDifferentPayloadCollides() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try PendantPageLedger(rootURL: root)
        let identity = pageIdentity()
        let payload = Data([1, 2, 3])
        _ = try ledger.ingest(payload, for: identity)

        guard case .duplicate = try ledger.ingest(payload, for: identity) else {
            return XCTFail("Expected duplicate result")
        }
        XCTAssertThrowsError(try ledger.ingest(Data([4]), for: identity)) { error in
            guard case .payloadCollision(let collisionID, _, _) = error as? PendantPageLedgerError else {
                return XCTFail("Expected payload collision, got \(error)")
            }
            XCTAssertEqual(collisionID, identity)
        }
    }

    func testVerificationRequiresMatchingRawAndAudioHashBeforeCleanup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try PendantPageLedger(rootURL: root)
        let identity = pageIdentity()
        _ = try ledger.ingest(Data([9]), for: identity)
        let hash = try XCTUnwrap(ledger.record(for: identity)?.rawPageHash)

        XCTAssertThrowsError(try ledger.markVerified(identity, rawPageHash: "wrong", audioHash: "audio"))
        try ledger.markVerified(identity, rawPageHash: hash, audioHash: "")
        XCTAssertFalse(ledger.permitsDeviceCleanup(for: identity))
        try ledger.markVerified(identity, rawPageHash: hash, audioHash: "audio-sha256")
        XCTAssertTrue(ledger.permitsDeviceCleanup(for: identity))

        let reloaded = try PendantPageLedger(rootURL: root)
        XCTAssertEqual(reloaded.record(for: identity)?.state, .verified)
        XCTAssertTrue(reloaded.permitsDeviceCleanup(for: identity))
    }

    func testUnsafeIdentityCannotEscapeVault() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try PendantPageLedger(rootURL: root)
        let unsafe = PendantPageIdentity(deviceID: "../outside", sessionID: "session", runID: "run", sequence: 0, pageIndex: 0)

        XCTAssertThrowsError(try ledger.ingest(Data([1]), for: unsafe)) { error in
            XCTAssertEqual(error as? PendantPageLedgerError, .unsafeIdentifier("../outside"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside").path))
    }

    private func pageIdentity() -> PendantPageIdentity {
        PendantPageIdentity(deviceID: "device-01", sessionID: "session_01", runID: "run.01", sequence: 3, pageIndex: 7)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PendantPageLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
