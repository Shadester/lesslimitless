import Foundation

public enum PendantWireError: Error, Equatable, Sendable {
    case invalidMaximumWriteLength
    case tooManyFragments
    case invalidFragmentCount
    case fragmentSequenceOutOfRange
    case payloadTooLarge
    case conflictingFragment
    case inconsistentFragmentCount
}

public enum PendantCommand: Equatable, Sendable {
    case setCurrentTime(millisecondsSince1970: Int64)
    case downloadFlashPages(batch: Bool, realTime: Bool)
    case getDeviceInfo
    case getDeviceStatus
}

public struct PendantFragment: Equatable, Sendable {
    public let index: UInt32
    public let sequence: UInt16
    public let count: UInt16
    public let payload: Data

    public init(index: UInt32, sequence: UInt16, count: UInt16, payload: Data) {
        self.index = index
        self.sequence = sequence
        self.count = count
        self.payload = payload
    }
}

public enum PendantWire {
    public static let maximumFragmentCount: UInt16 = 128
    public static let maximumPayloadBytes = 4 * 1_024 * 1_024

    /// Encodes the safe, non-destructive subset of pendant commands.
    public static func encodeApplicationCommand(
        _ command: PendantCommand,
        requestID: UInt32? = nil
    ) -> Data {
        let field: UInt64
        var body = Data()

        switch command {
        case let .setCurrentTime(milliseconds):
            field = 6
            ProtobufWire.appendVarintField(1, value: UInt64(bitPattern: milliseconds), to: &body)
        case let .downloadFlashPages(batch, realTime):
            field = 8
            ProtobufWire.appendVarintField(1, value: batch ? 1 : 0, to: &body)
            ProtobufWire.appendVarintField(2, value: realTime ? 1 : 0, to: &body)
        case .getDeviceInfo:
            field = 14
        case .getDeviceStatus:
            field = 21
        }

        var application = Data()
        ProtobufWire.appendBytesField(field, value: body, to: &application)
        if let requestID {
            var request = Data()
            ProtobufWire.appendVarintField(1, value: UInt64(requestID), to: &request)
            ProtobufWire.appendBytesField(30, value: request, to: &application)
        }
        return application
    }

    /// Splits an application message into BLE envelopes no larger than the
    /// transport's current maximum write length.
    public static func encodeFragments(
        payload: Data,
        messageIndex: UInt32,
        maximumWriteLength: Int
    ) throws -> [Data] {
        guard maximumWriteLength >= 16 else { throw PendantWireError.invalidMaximumWriteLength }
        guard payload.count <= maximumPayloadBytes else { throw PendantWireError.payloadTooLarge }

        if payload.isEmpty {
            return [encodeEnvelope(index: messageIndex, sequence: 0, count: 1, payload: Data())]
        }

        // Reserve enough room for worst-case keys/varints in our bounded envelope.
        let conservativeChunkSize = maximumWriteLength - 16
        guard conservativeChunkSize > 0 else { throw PendantWireError.invalidMaximumWriteLength }
        let required = (payload.count + conservativeChunkSize - 1) / conservativeChunkSize
        guard required <= Int(maximumFragmentCount), required <= Int(UInt16.max) else {
            throw PendantWireError.tooManyFragments
        }
        let count = UInt16(required)

        var result: [Data] = []
        result.reserveCapacity(required)
        var cursor = payload.startIndex
        for sequence in 0..<required {
            let end = payload.index(cursor, offsetBy: min(conservativeChunkSize, payload.distance(from: cursor, to: payload.endIndex)))
            let chunk = Data(payload[cursor..<end])
            let envelope = encodeEnvelope(
                index: messageIndex,
                sequence: UInt16(sequence),
                count: count,
                payload: chunk
            )
            guard envelope.count <= maximumWriteLength else {
                throw PendantWireError.invalidMaximumWriteLength
            }
            result.append(envelope)
            cursor = end
        }
        return result
    }

    public static func encodeEnvelope(
        index: UInt32,
        sequence: UInt16,
        count: UInt16,
        payload: Data
    ) -> Data {
        var envelope = Data()
        ProtobufWire.appendVarintField(1, value: UInt64(index), to: &envelope)
        ProtobufWire.appendVarintField(2, value: UInt64(sequence), to: &envelope)
        ProtobufWire.appendVarintField(3, value: UInt64(count), to: &envelope)
        ProtobufWire.appendBytesField(4, value: payload, to: &envelope)
        return envelope
    }

    public static func decodeEnvelope(_ data: Data) throws -> PendantFragment {
        var reader = ProtobufReader(data)
        var index: UInt64 = 0
        var sequence: UInt64 = 0
        var count: UInt64 = 1
        var payload: Data?

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = key >> 3
            let wireType = UInt8(key & 7)
            switch (field, wireType) {
            case (1, 0): index = try reader.readVarint()
            case (2, 0): sequence = try reader.readVarint()
            case (3, 0): count = try reader.readVarint()
            case (4, 2): payload = try reader.readBytes(maximum: maximumPayloadBytes)
            default: try reader.skip(wireType: wireType, maximumLength: maximumPayloadBytes)
            }
        }

        guard count > 0, count <= UInt64(maximumFragmentCount) else {
            throw PendantWireError.invalidFragmentCount
        }
        guard sequence < count, sequence <= UInt64(UInt16.max) else {
            throw PendantWireError.fragmentSequenceOutOfRange
        }
        guard index <= UInt64(UInt32.max) else { throw PendantWireError.payloadTooLarge }
        guard let payload else { throw ProtobufWireError.truncated }

        return PendantFragment(
            index: UInt32(index),
            sequence: UInt16(sequence),
            count: UInt16(count),
            payload: payload
        )
    }
}
