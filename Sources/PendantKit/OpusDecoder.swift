import COpus
import Foundation

/// Decodes packet-aligned Opus data produced at 16 kHz mono.
///
/// Raw Opus has no packet delimiter. Do not infer boundaries from payload bytes:
/// retain packet-aligned fields from the pendant protocol and pass them as an
/// array. The `rawPackets` overload rejects nonempty input by design.
public enum OpusDecoder {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let maximumPacketBytes = 1_275
    public static let maximumFrameSamples = 1_920
    public static let defaultMaximumInputBytes = 8 * 1_024 * 1_024
    public static let defaultMaximumOutputSamples = 16_000 * 60 * 30

    public enum Error: Swift.Error, Equatable, Sendable {
        case inputTooLarge(limit: Int)
        case outputTooLarge(limit: Int)
        case packetBoundariesRequired
        case malformedPacket(index: Int)
        case undecodablePacket(index: Int, code: Int32)
        case decoderUnavailable(code: Int32)
    }

    public static func decode(
        packets: [Data],
        maximumInputBytes: Int = defaultMaximumInputBytes,
        maximumOutputSamples: Int = defaultMaximumOutputSamples
    ) throws -> [Float] {
        guard maximumInputBytes >= 0, maximumOutputSamples >= 0 else {
            throw Error.outputTooLarge(limit: maximumOutputSamples)
        }
        var inputBytes = 0
        for packet in packets {
            guard packet.count <= maximumPacketBytes,
                  inputBytes <= maximumInputBytes - packet.count else {
                throw Error.inputTooLarge(limit: maximumInputBytes)
            }
            inputBytes += packet.count
        }
        guard !packets.isEmpty else { return [] }

        var creationError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(channels), &creationError) else {
            throw Error.decoderUnavailable(code: creationError)
        }
        defer { opus_decoder_destroy(decoder) }

        var pcm: [Float] = []
        for (index, packet) in packets.enumerated() {
            let sampleCount: Int32 = packet.withUnsafeBytes { bytes in
                guard let start = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return opus_packet_get_nb_samples(start, Int32(packet.count), Int32(sampleRate))
            }
            guard !packet.isEmpty, sampleCount > 0 else {
                throw Error.malformedPacket(index: index)
            }
            var frame = Array(repeating: Float.zero, count: maximumFrameSamples)
            let count: Int = try packet.withUnsafeBytes { bytes in
                guard let start = bytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw Error.malformedPacket(index: index)
                }
                let result = opus_decode_float(
                    decoder, start, Int32(packet.count), &frame,
                    Int32(maximumFrameSamples), 0
                )
                guard result >= 0 else { throw Error.undecodablePacket(index: index, code: result) }
                return Int(result)
            }
            guard count <= maximumFrameSamples,
                  pcm.count <= maximumOutputSamples - count else {
                throw Error.outputTooLarge(limit: maximumOutputSamples)
            }
            pcm.append(contentsOf: frame.prefix(count))
        }
        return pcm
    }

    /// Intentionally refuses undelimited nonempty raw streams. The pendant
    /// protocol must preserve individual codec payload boundaries for safe decode.
    public static func decode(
        rawPackets: Data,
        maximumInputBytes: Int = defaultMaximumInputBytes,
        maximumOutputSamples: Int = defaultMaximumOutputSamples
    ) throws -> [Float] {
        guard rawPackets.count <= maximumInputBytes else {
            throw Error.inputTooLarge(limit: maximumInputBytes)
        }
        guard rawPackets.isEmpty else { throw Error.packetBoundariesRequired }
        return try decode(packets: [], maximumInputBytes: maximumInputBytes, maximumOutputSamples: maximumOutputSamples)
    }
}
