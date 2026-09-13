import COpus
import Foundation
import XCTest
@testable import PendantKit

final class OpusDecoderTests: XCTestCase {
    func testDecodesPacketAlignedRealOpusAndWritesWAV() throws {
        let packets = try encodedPackets(frameSizes: [320, 320, 320])
        let pcm = try OpusDecoder.decode(packets: packets)
        XCTAssertEqual(pcm.count, 960)
        XCTAssertTrue(pcm.allSatisfy(\.isFinite))
        XCTAssertTrue(pcm.contains { abs($0) > 0.0001 })

        let wav = try WAVWriter.pcm16Data(samples: pcm)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(littleEndianUInt32(wav, at: 24), 16_000)
        XCTAssertEqual(littleEndianUInt32(wav, at: 40), UInt32(pcm.count * 2))
        XCTAssertEqual(wav.count, 44 + pcm.count * 2)
    }

    func testDecodesVariableDurationPacketsWhenBoundariesArePreserved() throws {
        let packets = try encodedPackets(frameSizes: [160, 320])
        let pcm = try OpusDecoder.decode(packets: packets)
        XCTAssertEqual(pcm.count, 480)
    }

    func testRejectsUndelimitedRawStream() throws {
        let packets = try encodedPackets(frameSizes: [320, 320])
        let raw = packets.reduce(into: Data()) { $0.append($1) }
        XCTAssertThrowsError(try OpusDecoder.decode(rawPackets: raw)) { error in
            XCTAssertEqual(error as? OpusDecoder.Error, .packetBoundariesRequired)
        }
    }

    func testRejectsMalformedPacketAndEnforcesOutputBound() throws {
        XCTAssertThrowsError(try OpusDecoder.decode(packets: [Data([0xff])])) { error in
            XCTAssertEqual(error as? OpusDecoder.Error, .malformedPacket(index: 0))
        }
        let packet = try encodedPackets(frameSizes: [320])[0]
        XCTAssertThrowsError(try OpusDecoder.decode(packets: [packet], maximumOutputSamples: 319)) { error in
            XCTAssertEqual(error as? OpusDecoder.Error, .outputTooLarge(limit: 319))
        }
    }

    func testWAVRejectsHeaderOverflow() {
        XCTAssertThrowsError(try WAVWriter.pcm16Data(samples: [], sampleRate: Int.max, channels: 1)) { error in
            XCTAssertEqual(error as? WAVWriter.Error, .fileTooLarge)
        }
        XCTAssertThrowsError(try WAVWriter.pcm16Data(samples: [], sampleRate: 16_000, channels: 65_536)) { error in
            XCTAssertEqual(error as? WAVWriter.Error, .invalidFormat)
        }
    }

    private func encodedPackets(frameSizes: [Int]) throws -> [Data] {
        var error: Int32 = 0
        guard let encoder = opus_encoder_create(16_000, 1, OPUS_APPLICATION_AUDIO, &error) else {
            throw NSError(domain: "OpusDecoderTests", code: Int(error))
        }
        defer { opus_encoder_destroy(encoder) }
        return try frameSizes.enumerated().map { frame, size in
            let input = (0..<size).map { Float(sin(Double($0 + frame * 7) * .pi * 2 / 32)) * 0.5 }
            var output = Array(repeating: UInt8.zero, count: OpusDecoder.maximumPacketBytes)
            let length = opus_encode_float(encoder, input, Int32(size), &output, Int32(output.count))
            guard length > 0 else { throw NSError(domain: "OpusDecoderTests", code: Int(length)) }
            return Data(output.prefix(Int(length)))
        }
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
