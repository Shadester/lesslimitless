import Foundation
import XCTest
@testable import PendantKit

final class FlashPageParserTests: XCTestCase {
    func testDecodesHandcraftedGoldenFlashPage() throws {
        var audio = Data()
        bytesField(1, [0x01], into: &audio) // omni PCM
        bytesField(2, [0x02], into: &audio) // directional PCM
        bytesField(3, [0x03], into: &audio) // beamforming PCM
        bytesField(4, [0xaa, 0xbb, 0xcc], into: &audio) // encoded Opus
        bytesField(5, [0x05], into: &audio)
        bytesField(7, [0x07], into: &audio)
        varintField(8, 1, into: &audio)
        varintField(9, 0, into: &audio)
        varintField(10, 1, into: &audio)
        varintField(11, 11, into: &audio)
        varintField(12, 12, into: &audio)
        bytesField(13, [0x00], into: &audio) // encrypted wrapper is present

        var chunk = Data()
        varintField(1, 9, into: &chunk)
        bytesField(2, audio, into: &chunk)

        var page = Data()
        varintField(1, 100, into: &page)
        varintField(2, 200, into: &page)
        bytesField(3, chunk, into: &page)

        let summary = try FlashPageParser().decode(page)
        XCTAssertEqual(summary.timestamp, 100)
        XCTAssertEqual(summary.bootUptime, 200)
        XCTAssertEqual(summary.chunks.count, 1)
        XCTAssertEqual(summary.chunks[0].timeOffset, 9)
        let decoded = try XCTUnwrap(summary.chunks[0].audioData)
        XCTAssertEqual(decoded.pcmOmni, Data([0x01]))
        XCTAssertEqual(decoded.pcmDirectional, Data([0x02]))
        XCTAssertEqual(decoded.pcmBeamforming, Data([0x03]))
        XCTAssertEqual(decoded.codecBeamforming, Data([0xaa, 0xbb, 0xcc]))
        XCTAssertEqual(decoded.codecManualBeamforming, Data([0x05]))
        XCTAssertEqual(decoded.pcmManualBeamforming, Data([0x07]))
        XCTAssertEqual(decoded.didStartRecording, true)
        XCTAssertEqual(decoded.didStopRecording, false)
        XCTAssertEqual(decoded.codecType, 1)
        XCTAssertEqual(decoded.numFrames, 11)
        XCTAssertEqual(decoded.degreeArrival, 12)
        XCTAssertTrue(decoded.hasEncryptedCodecPayload)
    }

    func testRejectsTruncatedLengthAndChunkLimit() throws {
        XCTAssertThrowsError(try FlashPageParser().decode(Data([0x1a, 0x04, 0x08]))) { error in
            XCTAssertEqual(error as? ProtobufWireError, .truncated)
        }

        let chunk = Data([0x08, 0x01])
        var page = Data()
        bytesField(3, chunk, into: &page)
        bytesField(3, chunk, into: &page)
        let parser = try FlashPageParser(maximumChunks: 1)
        XCTAssertThrowsError(try parser.decode(page)) { error in
            XCTAssertEqual(error as? FlashPageParserError, .chunkLimitExceeded)
        }
    }

    func testRejectsAudioAndNestedFieldLimits() throws {
        var audio = Data()
        bytesField(4, [0x01, 0x02, 0x03], into: &audio)
        var chunk = Data()
        bytesField(2, audio, into: &chunk)
        var page = Data()
        bytesField(3, chunk, into: &page)

        let parser = try FlashPageParser(maximumAudioBytes: 2)
        XCTAssertThrowsError(try parser.decode(page)) { error in
            XCTAssertEqual(error as? ProtobufWireError, .invalidLength)
        }

        let fieldLimited = try FlashPageParser(maximumFieldBytes: 1)
        XCTAssertThrowsError(try fieldLimited.decode(page)) { error in
            XCTAssertEqual(error as? ProtobufWireError, .invalidLength)
        }

        let nestingLimited = try FlashPageParser(maximumNesting: 1)
        XCTAssertThrowsError(try nestingLimited.decode(page)) { error in
            XCTAssertEqual(error as? FlashPageParserError, .nestingLimitExceeded)
        }
    }

    private func varintField(_ field: UInt64, _ value: UInt64, into data: inout Data) {
        appendVarint((field << 3) | 0, into: &data)
        appendVarint(value, into: &data)
    }

    private func bytesField(_ field: UInt64, _ value: some Sequence<UInt8>, into data: inout Data) {
        let bytes = Data(value)
        appendVarint((field << 3) | 2, into: &data)
        appendVarint(UInt64(bytes.count), into: &data)
        data.append(bytes)
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
