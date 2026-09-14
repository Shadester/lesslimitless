import Foundation

/// Length-framed local representation of packet-aligned Opus. This is not an
/// Ogg container and must not be sent back to the pendant. Each packet is
/// encoded as a big-endian UInt32 length followed by packet bytes.
public enum OpusPacketStream {
    public enum Error: Swift.Error, Equatable, Sendable {
        case packetTooLarge(index: Int)
        case malformedLength(offset: Int)
        case truncatedPacket(offset: Int)
    }

    public static func encode(_ packets: [Data]) throws -> Data {
        var output = Data()
        for (index, packet) in packets.enumerated() {
            guard packet.count <= OpusDecoder.maximumPacketBytes else { throw Error.packetTooLarge(index: index) }
            var length = UInt32(packet.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(packet)
        }
        return output
    }

    public static func decode(_ data: Data) throws -> [Data] {
        var offset = 0
        var packets: [Data] = []
        while offset < data.count {
            guard data.count - offset >= 4 else { throw Error.truncatedPacket(offset: offset) }
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard length <= UInt32(OpusDecoder.maximumPacketBytes) else { throw Error.malformedLength(offset: offset - 4) }
            let count = Int(length)
            guard count <= data.count - offset else { throw Error.truncatedPacket(offset: offset) }
            packets.append(Data(data[offset..<(offset + count)]))
            offset += count
        }
        return packets
    }
}
