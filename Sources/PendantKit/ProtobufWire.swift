import Foundation

public enum ProtobufWireError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case unsupportedWireType(UInt8)
    case invalidLength
}

enum ProtobufWire {
    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    static func appendVarintField(_ field: UInt64, value: UInt64, to data: inout Data) {
        appendVarint(field << 3, to: &data)
        appendVarint(value, to: &data)
    }

    static func appendBytesField(_ field: UInt64, value: Data, to data: inout Data) {
        appendVarint((field << 3) | 2, to: &data)
        appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }
}

struct ProtobufReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < bytes.count else { throw ProtobufWireError.truncated }
            let byte = bytes[offset]
            offset += 1
            if shift == 63, byte > 1 { throw ProtobufWireError.malformedVarint }
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw ProtobufWireError.malformedVarint
    }

    mutating func readBytes(maximum: Int) throws -> Data {
        let rawLength = try readVarint()
        guard rawLength <= UInt64(maximum), rawLength <= UInt64(Int.max) else {
            throw ProtobufWireError.invalidLength
        }
        let length = Int(rawLength)
        guard length <= bytes.count - offset else { throw ProtobufWireError.truncated }
        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }

    mutating func skip(wireType: UInt8, maximumLength: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            try advance(by: 8)
        case 2:
            _ = try readBytes(maximum: maximumLength)
        case 5:
            try advance(by: 4)
        default:
            throw ProtobufWireError.unsupportedWireType(wireType)
        }
    }

    private mutating func advance(by count: Int) throws {
        guard count <= bytes.count - offset else { throw ProtobufWireError.truncated }
        offset += count
    }
}
