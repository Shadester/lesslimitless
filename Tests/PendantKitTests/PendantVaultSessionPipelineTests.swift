import Foundation
import XCTest
@testable import PendantKit

final class PendantVaultSessionPipelineTests: XCTestCase {
    func testRecoversAcrossNewPipelineInstancesAndArchivesRawOpus() throws {
        let vault = try makeRoot()
        let archives = try makeRoot()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: archives) }
        let identity = pageIdentity()
        let payload = opusPage(timestamp: 1_000, opus: Data([1, 2, 3]))
        _ = try PendantPageLedger(rootURL: vault).ingest(payload, for: identity)

        let report = try PendantVaultSessionPipeline(vaultRootURL: vault).archive(to: archives)

        XCTAssertEqual(report.loadedPageIdentities, [identity])
        XCTAssertTrue(report.failedPages.isEmpty)
        let archived = try XCTUnwrap(report.archivedSessions.first)
        XCTAssertEqual(try Data(contentsOf: archived.archive.opusURL), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.archive.manifestURL.path))
    }

    func testReportsCorruptedRawPageHashMismatchWithoutArchiving() throws {
        let vault = try makeRoot()
        let archives = try makeRoot()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: archives) }
        let identity = pageIdentity()
        let ledger = try PendantPageLedger(rootURL: vault)
        _ = try ledger.ingest(opusPage(timestamp: 1, opus: Data([1])), for: identity)
        try Data([0xff]).write(to: ledger.rawPageURL(for: identity), options: .atomic)

        let report = try PendantVaultSessionPipeline(vaultRootURL: vault).archive(to: archives)

        XCTAssertEqual(report.loadedPageIdentities, [])
        XCTAssertEqual(report.failedPages.count, 1)
        guard case .rawPageHashMismatch(let failed, _, _) = report.failedPages[0] else {
            return XCTFail("Expected raw hash mismatch")
        }
        XCTAssertEqual(failed, identity)
        XCTAssertTrue(report.archivedSessions.isEmpty)
    }

    func testExcludesFailedRecordsAndReportsTheirIdentity() throws {
        let vault = try makeRoot()
        let archives = try makeRoot()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: archives) }
        let identity = pageIdentity()
        let ledger = try PendantPageLedger(rootURL: vault)
        _ = try ledger.ingest(opusPage(timestamp: 1, opus: Data([1])), for: identity)
        try ledger.markFailed(identity, reason: "transfer failed")

        let report = try PendantVaultSessionPipeline(ledger: try PendantPageLedger(rootURL: vault)).archive(to: archives)

        XCTAssertTrue(report.loadedPageIdentities.isEmpty)
        XCTAssertEqual(report.failedPages, [.failedRecord(identity, reason: "transfer failed")])
        XCTAssertTrue(report.archivedSessions.isEmpty)
    }

    func testArchiveIDIsDeterministicAndUsesRecordingIdentityAndManifestIndex() {
        let first = PendantVaultSessionPipeline.archiveID(deviceID: "device", sessionID: "session", runID: "run", manifestIndex: 0)
        XCTAssertEqual(first, PendantVaultSessionPipeline.archiveID(deviceID: "device", sessionID: "session", runID: "run", manifestIndex: 0))
        XCTAssertNotEqual(first, PendantVaultSessionPipeline.archiveID(deviceID: "device", sessionID: "session", runID: "run", manifestIndex: 1))
        XCTAssertTrue(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    func testExpandedRecordingGetsNewArchiveInsteadOfCollision() throws {
        let vault = try makeRoot()
        let archives = try makeRoot()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: archives) }
        let ledger = try PendantPageLedger(rootURL: vault)
        _ = try ledger.ingest(opusPage(timestamp: 1, opus: Data([1])), for: pageIdentity(sequence: 0))
        let first = try PendantVaultSessionPipeline(ledger: ledger).archive(to: archives)
        let firstID = try XCTUnwrap(first.archivedSessions.first?.archiveID)

        _ = try ledger.ingest(opusPage(timestamp: 2, opus: Data([2])), for: pageIdentity(sequence: 1))
        let expanded = try PendantVaultSessionPipeline(ledger: ledger).archive(to: archives)
        let expandedID = try XCTUnwrap(expanded.archivedSessions.first?.archiveID)

        XCTAssertNotEqual(firstID, expandedID)
        XCTAssertEqual(try Data(contentsOf: expanded.archivedSessions[0].archive.opusURL), Data([1, 2]))
    }

    func testKnownFailedPageQuarantinesItsWholeRecordingGroup() throws {
        let vault = try makeRoot()
        let archives = try makeRoot()
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: archives) }
        let ledger = try PendantPageLedger(rootURL: vault)
        let failed = pageIdentity(sequence: 0)
        let otherwiseValid = pageIdentity(sequence: 1)
        _ = try ledger.ingest(opusPage(timestamp: 1, opus: Data([1])), for: failed)
        _ = try ledger.ingest(opusPage(timestamp: 2, opus: Data([2])), for: otherwiseValid)
        try ledger.markFailed(failed, reason: "corrupt")

        let report = try PendantVaultSessionPipeline(ledger: ledger).archive(to: archives)
        XCTAssertTrue(report.archivedSessions.isEmpty)
        XCTAssertTrue(report.failedPages.contains(.failedRecord(failed, reason: "corrupt")))
        XCTAssertTrue(report.failedPages.contains(.quarantinedIncompleteRecording(otherwiseValid)))
    }

    private func pageIdentity(sequence: Int = 0) -> PendantPageIdentity {
        PendantPageIdentity(deviceID: "device", sessionID: "session", runID: "run", sequence: sequence, pageIndex: sequence)
    }

    private func opusPage(timestamp: UInt64, opus: Data) -> Data {
        var audio = Data()
        appendVarint(4 << 3 | 2, to: &audio)
        appendVarint(UInt64(opus.count), to: &audio)
        audio.append(opus)
        appendVarint(10 << 3, to: &audio)
        appendVarint(1, to: &audio)

        var chunk = Data()
        appendVarint(2 << 3 | 2, to: &chunk)
        appendVarint(UInt64(audio.count), to: &chunk)
        chunk.append(audio)

        var page = Data()
        appendVarint(1 << 3, to: &page)
        appendVarint(timestamp, to: &page)
        appendVarint(3 << 3 | 2, to: &page)
        appendVarint(UInt64(chunk.count), to: &page)
        page.append(chunk)
        return page
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendantVaultSessionPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
