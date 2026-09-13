import Foundation

public struct PendantStorageBuffer: Equatable, Sendable {
    public let ingestType: UInt64?
    public let session: UInt64?
    public let run: UInt64?
    public let sequence: UInt64?
    public let pageIndex: UInt64?
    public let flashPage: Data?
    public let pageError: UInt64?

    public init(
        ingestType: UInt64?, session: UInt64?, run: UInt64?, sequence: UInt64?,
        pageIndex: UInt64?, flashPage: Data?, pageError: UInt64?
    ) {
        self.ingestType = ingestType
        self.session = session
        self.run = run
        self.sequence = sequence
        self.pageIndex = pageIndex
        self.flashPage = flashPage
        self.pageError = pageError
    }
}

public enum PendantStorageBufferError: Error, Equatable, Sendable {
    case missingFlashPage
    case valueOutOfRange
}

/// Extracts a `StorageBufferMsg` (field 2) from a reassembled `PendantAllMsg`.
/// This does not interpret, ACK, or delete any device data.
public enum PendantStorageBufferParser {
    public static func decode(from pendantAllMessage: Data, maximumPageBytes: Int = PendantWire.maximumPayloadBytes) throws -> PendantStorageBuffer? {
        var reader = ProtobufReader(pendantAllMessage)
        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = key >> 3
            let wireType = UInt8(key & 7)
            if field == 2, wireType == 2 {
                return try decodeStorageBuffer(reader.readBytes(maximum: maximumPageBytes), maximumPageBytes: maximumPageBytes)
            }
            try reader.skip(wireType: wireType, maximumLength: maximumPageBytes)
        }
        return nil
    }

    private static func decodeStorageBuffer(_ data: Data, maximumPageBytes: Int) throws -> PendantStorageBuffer {
        var reader = ProtobufReader(data)
        var ingestType: UInt64?
        var session: UInt64?
        var run: UInt64?
        var sequence: UInt64?
        var pageIndex: UInt64?
        var flashPage: Data?
        var pageError: UInt64?

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            switch (key >> 3, UInt8(key & 7)) {
            case (1, 0): ingestType = try reader.readVarint()
            case (2, 0): session = try reader.readVarint()
            case (3, 0): run = try reader.readVarint()
            case (4, 0): sequence = try reader.readVarint()
            case (5, 0): pageIndex = try reader.readVarint()
            case (6, 2): flashPage = try reader.readBytes(maximum: maximumPageBytes)
            case (7, 0): pageError = try reader.readVarint()
            default: try reader.skip(wireType: UInt8(key & 7), maximumLength: maximumPageBytes)
            }
        }
        guard flashPage != nil || (pageError ?? 0) != 0 else { throw PendantStorageBufferError.missingFlashPage }
        return PendantStorageBuffer(
            ingestType: ingestType, session: session, run: run, sequence: sequence,
            pageIndex: pageIndex, flashPage: flashPage, pageError: pageError
        )
    }
}
