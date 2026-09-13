import Foundation
import XCTest
@testable import PendantKit

final class PendantWireTests: XCTestCase {
    func testKnownCommandEncodings() {
        XCTAssertEqual(
            hex(PendantWire.encodeApplicationCommand(.getDeviceInfo)),
            "7200"
        )
        XCTAssertEqual(
            hex(PendantWire.encodeApplicationCommand(.getDeviceStatus)),
            "aa0100"
        )
        XCTAssertEqual(
            hex(PendantWire.encodeApplicationCommand(.downloadFlashPages(batch: true, realTime: false))),
            "420408011000"
        )
        XCTAssertEqual(
            hex(PendantWire.encodeApplicationCommand(.setCurrentTime(millisecondsSince1970: 1_704_067_200_000))),
            "32070880e8c792cc31"
        )
        XCTAssertEqual(
            hex(PendantWire.encodeApplicationCommand(.getDeviceStatus, requestID: 7)),
            "aa0100f201020807"
        )
    }

    func testKnownSingleFragmentEnvelope() throws {
        let command = PendantWire.encodeApplicationCommand(.getDeviceInfo)
        let envelope = PendantWire.encodeEnvelope(index: 0, sequence: 0, count: 1, payload: command)
        XCTAssertEqual(hex(envelope), "08001000180122027200")
        XCTAssertEqual(
            try PendantWire.decodeEnvelope(envelope),
            PendantFragment(index: 0, sequence: 0, count: 1, payload: command)
        )
    }

    func testFragmentationRespectsMaximumWriteLengthAndRoundTrips() async throws {
        let payload = Data((0..<200).map(UInt8.init))
        let encoded = try PendantWire.encodeFragments(
            payload: payload,
            messageIndex: 42,
            maximumWriteLength: 40
        )
        XCTAssertGreaterThan(encoded.count, 1)
        XCTAssertTrue(encoded.allSatisfy { $0.count <= 40 })

        let reassembler = FragmentReassembler()
        var result: Data?
        for bytes in encoded.reversed() {
            let fragment = try PendantWire.decodeEnvelope(bytes)
            if let complete = try await reassembler.receive(fragment) {
                result = complete
            }
        }
        XCTAssertEqual(result, payload)
    }

    func testDecoderRejectsInvalidCountAndSequence() {
        let zeroCount = PendantWire.encodeEnvelope(index: 1, sequence: 0, count: 0, payload: Data([1]))
        XCTAssertThrowsError(try PendantWire.decodeEnvelope(zeroCount)) { error in
            XCTAssertEqual(error as? PendantWireError, .invalidFragmentCount)
        }

        let badSequence = PendantWire.encodeEnvelope(index: 1, sequence: 2, count: 2, payload: Data([1]))
        XCTAssertThrowsError(try PendantWire.decodeEnvelope(badSequence)) { error in
            XCTAssertEqual(error as? PendantWireError, .fragmentSequenceOutOfRange)
        }
    }

    func testDecoderRejectsTruncatedLengthDelimitedField() {
        let truncated = Data([0x08, 0x01, 0x18, 0x01, 0x22, 0x05, 0xaa])
        XCTAssertThrowsError(try PendantWire.decodeEnvelope(truncated)) { error in
            XCTAssertEqual(error as? ProtobufWireError, .truncated)
        }
    }

    func testDecodesKnownInboundFixture() throws {
        let bytes = Data([0x08, 0x01, 0x18, 0x01, 0x22, 0x0c] + Array("test_payload".utf8))
        let fragment = try PendantWire.decodeEnvelope(bytes)
        XCTAssertEqual(fragment.index, 1)
        XCTAssertEqual(fragment.sequence, 0)
        XCTAssertEqual(fragment.count, 1)
        XCTAssertEqual(fragment.payload, Data("test_payload".utf8))
    }

    func testDecoderRejectsMalformedVarint() {
        XCTAssertThrowsError(try PendantWire.decodeEnvelope(Data(repeating: 0x80, count: 11))) { error in
            XCTAssertEqual(error as? ProtobufWireError, .malformedVarint)
        }
    }

    func testDuplicateFragmentIsIdempotentButConflictFails() async throws {
        let reassembler = FragmentReassembler()
        let first = PendantFragment(index: 9, sequence: 0, count: 2, payload: Data("a".utf8))
        let firstResult = try await reassembler.receive(first)
        let duplicateResult = try await reassembler.receive(first)
        XCTAssertNil(firstResult)
        XCTAssertNil(duplicateResult)

        let conflicting = PendantFragment(index: 9, sequence: 0, count: 2, payload: Data("b".utf8))
        do {
            _ = try await reassembler.receive(conflicting)
            XCTFail("Expected a conflicting fragment error")
        } catch {
            XCTAssertEqual(error as? PendantWireError, .conflictingFragment)
        }
        let pendingAfterConflict = await reassembler.pendingMessageCount
        XCTAssertEqual(pendingAfterConflict, 0)
    }

    func testInconsistentFragmentCountDiscardsMessage() async throws {
        let reassembler = FragmentReassembler()
        _ = try await reassembler.receive(PendantFragment(index: 5, sequence: 0, count: 2, payload: Data([1])))
        do {
            _ = try await reassembler.receive(PendantFragment(index: 5, sequence: 1, count: 3, payload: Data([2])))
            XCTFail("Expected inconsistent fragment count")
        } catch {
            XCTAssertEqual(error as? PendantWireError, .inconsistentFragmentCount)
        }
        let pending = await reassembler.pendingMessageCount
        XCTAssertEqual(pending, 0)
    }

    func testOldestPendingMessageIsEvictedAtCapacity() async throws {
        let reassembler = FragmentReassembler(timeout: 60, maximumPendingMessages: 1)
        let start = Date(timeIntervalSince1970: 100)
        _ = try await reassembler.receive(PendantFragment(index: 1, sequence: 0, count: 2, payload: Data([1])), now: start)
        _ = try await reassembler.receive(PendantFragment(index: 2, sequence: 0, count: 2, payload: Data([2])), now: start.addingTimeInterval(1))
        let pending = await reassembler.pendingMessageCount
        XCTAssertEqual(pending, 1)
    }

    func testIncompleteMessagesExpire() async throws {
        let reassembler = FragmentReassembler(timeout: 1)
        let start = Date(timeIntervalSince1970: 100)
        let fragment = PendantFragment(index: 3, sequence: 0, count: 2, payload: Data([1]))
        let result = try await reassembler.receive(fragment, now: start)
        XCTAssertNil(result)
        let beforeExpiry = await reassembler.pendingMessageCount
        XCTAssertEqual(beforeExpiry, 1)
        await reassembler.expire(at: start.addingTimeInterval(2))
        let afterExpiry = await reassembler.pendingMessageCount
        XCTAssertEqual(afterExpiry, 0)
    }

    func testPublicCommandsContainNoDestructiveOperation() {
        let commands: [PendantCommand] = [
            .getDeviceInfo,
            .getDeviceStatus,
            .setCurrentTime(millisecondsSince1970: 0),
            .downloadFlashPages(batch: true, realTime: false)
        ]
        XCTAssertEqual(commands.count, 4)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
