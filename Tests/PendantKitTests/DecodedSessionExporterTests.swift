import COpus
import Foundation
import XCTest
@testable import PendantKit

final class DecodedSessionExporterTests: XCTestCase {
    func testExportsPacketAlignedSessionAsAtomicWAVAndIsIdempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(packets: try encodedPackets(frameSizes: [320, 320]))
        let exporter = try DecodedSessionExporter(rootURL: root)

        let first = try exporter.export(session, sessionID: "session_01")
        let wav = try Data(contentsOf: first.wavURL)
        XCTAssertEqual(first.wavURL.deletingLastPathComponent(), root.appendingPathComponent("session_01.wav.export", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(littleEndianUInt32(wav, at: 24), 16_000)
        XCTAssertEqual(littleEndianUInt32(wav, at: 40), 1_280)
        XCTAssertEqual(wav.count, 1_324)
        XCTAssertEqual(try JSONDecoder().decode(DecodedSessionExportManifest.self, from: Data(contentsOf: first.manifestURL)), first.manifest)

        XCTAssertEqual(try exporter.export(session, sessionID: "session_01"), first)
    }

    func testDifferentPacketAlignedSessionForSameIDCollides() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = try DecodedSessionExporter(rootURL: root)
        _ = try exporter.export(makeSession(packets: try encodedPackets(frameSizes: [320])), sessionID: "session")

        XCTAssertThrowsError(try exporter.export(makeSession(packets: try encodedPackets(frameSizes: [160])), sessionID: "session")) { error in
            guard case .collision(let sessionID, _, _) = error as? DecodedSessionExporterError else {
                return XCTFail("Expected collision, got \(error)")
            }
            XCTAssertEqual(sessionID, "session")
        }
    }

    func testRejectsEmptyPacketsAndUnsafeSessionID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = try DecodedSessionExporter(rootURL: root)
        let empty = makeSession(packets: [])

        XCTAssertThrowsError(try exporter.export(empty, sessionID: "session")) {
            XCTAssertEqual($0 as? DecodedSessionExporterError, .noPackets)
        }
        XCTAssertThrowsError(try exporter.export(empty, sessionID: "../outside")) {
            XCTAssertEqual($0 as? DecodedSessionExporterError, .unsafeSessionID("../outside"))
        }
    }

    private func makeSession(packets: [Data]) -> PendantSessionManifest {
        let identity = PendantPageIdentity(deviceID: "device", sessionID: "source", runID: "run", sequence: 1, pageIndex: 1)
        return PendantSessionManifest(index: 0, contributions: [PendantSessionPageContribution(identity: identity, timestamp: 0, encodedOpusBytes: packets)], openingBoundary: nil, closingBoundary: nil)
    }

    private func encodedPackets(frameSizes: [Int]) throws -> [Data] {
        var error: Int32 = 0
        guard let encoder = opus_encoder_create(16_000, 1, OPUS_APPLICATION_AUDIO, &error) else {
            throw NSError(domain: "DecodedSessionExporterTests", code: Int(error))
        }
        defer { opus_encoder_destroy(encoder) }
        return try frameSizes.enumerated().map { frame, size in
            let input = (0..<size).map { Float(sin(Double($0 + frame * 7) * .pi * 2 / 32)) * 0.5 }
            var output = Array(repeating: UInt8.zero, count: OpusDecoder.maximumPacketBytes)
            let length = opus_encode_float(encoder, input, Int32(size), &output, Int32(output.count))
            guard length > 0 else { throw NSError(domain: "DecodedSessionExporterTests", code: Int(length)) }
            return Data(output.prefix(Int(length)))
        }
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DecodedSessionExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
