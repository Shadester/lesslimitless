import Foundation
import XCTest
@testable import PendantKit

final class PendantStorageBufferTests: XCTestCase {
    func testDecodesStorageBufferAndIgnoresOtherResponseTypes() throws {
        let message = makePendantAllMessage()
        let buffer = try XCTUnwrap(PendantStorageBufferParser.decode(from: message))
        XCTAssertEqual(buffer.ingestType, 1)
        XCTAssertEqual(buffer.session, 2)
        XCTAssertEqual(buffer.run, 3)
        XCTAssertEqual(buffer.sequence, 4)
        XCTAssertEqual(buffer.pageIndex, 5)
        XCTAssertEqual(buffer.flashPage, Data([0x08, 0x64]))
        XCTAssertEqual(buffer.pageError, 0)

        var statusOnly = Data()
        bytesField(5, Data(), into: &statusOnly)
        XCTAssertNil(try PendantStorageBufferParser.decode(from: statusOnly))
    }

    func testIngestorStoresFlashPageIdempotently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendantPageIngestorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ingestor = try PendantPageIngestor(rootURL: root)
        let message = makePendantAllMessage()

        let firstOptional = try await ingestor.ingest(message, deviceID: "device-01")
        let first = try XCTUnwrap(firstOptional)
        guard case .stored = first.result else { return XCTFail("Expected initial storage") }
        XCTAssertEqual(first.summary?.timestamp, 100)
        let countAfterFirst = await ingestor.recordCount()
        XCTAssertEqual(countAfterFirst, 1)
        let duplicateOptional = try await ingestor.ingest(message, deviceID: "device-01")
        let duplicate = try XCTUnwrap(duplicateOptional)
        guard case .duplicate = duplicate.result else { return XCTFail("Expected duplicate") }
        let countAfterDuplicate = await ingestor.recordCount()
        XCTAssertEqual(countAfterDuplicate, 1)
    }

    func testIngestorRejectsStoragePageWithoutIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendantPageIngestorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ingestor = try PendantPageIngestor(rootURL: root)
        var storage = Data()
        bytesField(6, Data([0x08, 0x64]), into: &storage)
        var message = Data()
        bytesField(2, storage, into: &message)

        do {
            _ = try await ingestor.ingest(message, deviceID: "device-01")
            XCTFail("Expected missing identity error")
        } catch {
            XCTAssertEqual(error as? PendantPageIngestorError, .missingIdentityField("session"))
        }
    }

    private func makePendantAllMessage() -> Data {
        var storage = Data()
        varintField(1, 1, into: &storage)
        varintField(2, 2, into: &storage)
        varintField(3, 3, into: &storage)
        varintField(4, 4, into: &storage)
        varintField(5, 5, into: &storage)
        bytesField(6, Data([0x08, 0x64]), into: &storage)
        varintField(7, 0, into: &storage)
        var message = Data()
        bytesField(2, storage, into: &message)
        return message
    }

    private func varintField(_ field: UInt64, _ value: UInt64, into data: inout Data) {
        appendVarint(field << 3, into: &data)
        appendVarint(value, into: &data)
    }

    private func bytesField(_ field: UInt64, _ value: Data, into data: inout Data) {
        appendVarint((field << 3) | 2, into: &data)
        appendVarint(UInt64(value.count), into: &data)
        data.append(value)
    }

    private func appendVarint(_ value: UInt64, into data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}
