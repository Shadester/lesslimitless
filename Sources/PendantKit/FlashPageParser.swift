import Foundation

public enum FlashPageParserError: Error, Equatable, Sendable {
    case invalidLimits
    case nestingLimitExceeded
    case chunkLimitExceeded
    case audioBytesLimitExceeded
}

public struct FlashPageSummary: Equatable, Sendable {
    public let timestamp: UInt64?
    public let bootUptime: UInt64?
    public let chunks: [FlashPageChunk]

    public init(timestamp: UInt64?, bootUptime: UInt64?, chunks: [FlashPageChunk]) {
        self.timestamp = timestamp
        self.bootUptime = bootUptime
        self.chunks = chunks
    }
}

public struct FlashPageChunk: Equatable, Sendable {
    public let timeOffset: UInt64?
    public let audioData: FlashPageAudio?

    public init(timeOffset: UInt64?, audioData: FlashPageAudio?) {
        self.timeOffset = timeOffset
        self.audioData = audioData
    }
}

/// Raw audio fields and metadata from one `PendantAudioData` protobuf. Chunks
/// may contain other status fields, which this parser intentionally skips.
public struct FlashPageAudio: Equatable, Sendable {
    public let pcmOmni: Data?
    public let pcmDirectional: Data?
    public let pcmBeamforming: Data?
    public let codecBeamforming: Data?
    public let codecManualBeamforming: Data?
    public let pcmManualBeamforming: Data?
    public let didStartRecording: Bool?
    public let didStopRecording: Bool?
    public let codecType: UInt64?
    public let numFrames: UInt64?
    public let degreeArrival: UInt64?
    public let hasEncryptedCodecPayload: Bool

    public init(
        pcmOmni: Data?,
        pcmDirectional: Data?,
        pcmBeamforming: Data?,
        codecBeamforming: Data?,
        codecManualBeamforming: Data?,
        pcmManualBeamforming: Data?,
        didStartRecording: Bool?,
        didStopRecording: Bool?,
        codecType: UInt64?,
        numFrames: UInt64?,
        degreeArrival: UInt64?,
        hasEncryptedCodecPayload: Bool
    ) {
        self.pcmOmni = pcmOmni
        self.pcmDirectional = pcmDirectional
        self.pcmBeamforming = pcmBeamforming
        self.codecBeamforming = codecBeamforming
        self.codecManualBeamforming = codecManualBeamforming
        self.pcmManualBeamforming = pcmManualBeamforming
        self.didStartRecording = didStartRecording
        self.didStopRecording = didStopRecording
        self.codecType = codecType
        self.numFrames = numFrames
        self.degreeArrival = degreeArrival
        self.hasEncryptedCodecPayload = hasEncryptedCodecPayload
    }

    /// The common playable stream on known firmware.
    public var preferredEncodedAudio: Data? { codecBeamforming ?? codecManualBeamforming }
}

/// A bounded, non-destructive decoder for a pendant `FlashPage` protobuf.
public struct FlashPageParser: Sendable {
    public let maximumNesting: Int
    public let maximumChunks: Int
    public let maximumAudioBytes: Int
    public let maximumFieldBytes: Int

    public init(
        maximumNesting: Int = 2,
        maximumChunks: Int = 1_024,
        maximumAudioBytes: Int = 4 * 1_024 * 1_024,
        maximumFieldBytes: Int = 4 * 1_024 * 1_024
    ) throws {
        guard maximumNesting >= 0, maximumChunks >= 0,
              maximumAudioBytes >= 0, maximumFieldBytes >= 0 else {
            throw FlashPageParserError.invalidLimits
        }
        self.maximumNesting = maximumNesting
        self.maximumChunks = maximumChunks
        self.maximumAudioBytes = maximumAudioBytes
        self.maximumFieldBytes = maximumFieldBytes
    }

    public func decode(_ data: Data) throws -> FlashPageSummary {
        var audioByteCount = 0
        return try parsePage(data, depth: 0, audioByteCount: &audioByteCount)
    }

    private func parsePage(_ data: Data, depth: Int, audioByteCount: inout Int) throws -> FlashPageSummary {
        try requireDepth(depth)
        var reader = ProtobufReader(data)
        var timestamp: UInt64?
        var bootUptime: UInt64?
        var chunks: [FlashPageChunk] = []

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            switch (key >> 3, UInt8(key & 7)) {
            case (1, 0): timestamp = try reader.readVarint()
            case (2, 0): bootUptime = try reader.readVarint()
            case (3, 2):
                guard chunks.count < maximumChunks else { throw FlashPageParserError.chunkLimitExceeded }
                chunks.append(try parseChunk(
                    reader.readBytes(maximum: maximumFieldBytes),
                    depth: depth + 1,
                    audioByteCount: &audioByteCount
                ))
            default: try reader.skip(wireType: UInt8(key & 7), maximumLength: maximumFieldBytes)
            }
        }
        return FlashPageSummary(timestamp: timestamp, bootUptime: bootUptime, chunks: chunks)
    }

    private func parseChunk(_ data: Data, depth: Int, audioByteCount: inout Int) throws -> FlashPageChunk {
        try requireDepth(depth)
        var reader = ProtobufReader(data)
        var timeOffset: UInt64?
        var audioData: FlashPageAudio?

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            switch (key >> 3, UInt8(key & 7)) {
            case (1, 0): timeOffset = try reader.readVarint()
            case (2, 2): audioData = try parseAudio(
                reader.readBytes(maximum: maximumFieldBytes),
                depth: depth + 1,
                audioByteCount: &audioByteCount
            )
            default: try reader.skip(wireType: UInt8(key & 7), maximumLength: maximumFieldBytes)
            }
        }
        return FlashPageChunk(timeOffset: timeOffset, audioData: audioData)
    }

    private func parseAudio(_ data: Data, depth: Int, audioByteCount: inout Int) throws -> FlashPageAudio {
        try requireDepth(depth)
        var reader = ProtobufReader(data)
        var pcmOmni: Data?
        var pcmDirectional: Data?
        var pcmBeamforming: Data?
        var codecBeamforming: Data?
        var codecManualBeamforming: Data?
        var pcmManualBeamforming: Data?
        var didStart: Bool?
        var didStop: Bool?
        var codecType: UInt64?
        var numFrames: UInt64?
        var degreeArrival: UInt64?
        var encrypted = false

        func readAudioBytes(_ reader: inout ProtobufReader) throws -> Data {
            guard audioByteCount <= maximumAudioBytes else { throw FlashPageParserError.audioBytesLimitExceeded }
            let value = try reader.readBytes(maximum: maximumAudioBytes - audioByteCount)
            audioByteCount += value.count
            return value
        }

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            switch (key >> 3, UInt8(key & 7)) {
            case (1, 2): pcmOmni = try readAudioBytes(&reader)
            case (2, 2): pcmDirectional = try readAudioBytes(&reader)
            case (3, 2): pcmBeamforming = try readAudioBytes(&reader)
            case (4, 2): codecBeamforming = try readAudioBytes(&reader)
            case (5, 2): codecManualBeamforming = try readAudioBytes(&reader)
            case (7, 2): pcmManualBeamforming = try readAudioBytes(&reader)
            case (8, 0): didStart = try reader.readVarint() != 0
            case (9, 0): didStop = try reader.readVarint() != 0
            case (10, 0): codecType = try reader.readVarint()
            case (11, 0): numFrames = try reader.readVarint()
            case (12, 0): degreeArrival = try reader.readVarint()
            case (13, 2):
                _ = try reader.readBytes(maximum: maximumFieldBytes)
                encrypted = true
            default: try reader.skip(wireType: UInt8(key & 7), maximumLength: maximumFieldBytes)
            }
        }
        return FlashPageAudio(
            pcmOmni: pcmOmni,
            pcmDirectional: pcmDirectional,
            pcmBeamforming: pcmBeamforming,
            codecBeamforming: codecBeamforming,
            codecManualBeamforming: codecManualBeamforming,
            pcmManualBeamforming: pcmManualBeamforming,
            didStartRecording: didStart,
            didStopRecording: didStop,
            codecType: codecType,
            numFrames: numFrames,
            degreeArrival: degreeArrival,
            hasEncryptedCodecPayload: encrypted
        )
    }

    private func requireDepth(_ depth: Int) throws {
        guard depth <= maximumNesting else { throw FlashPageParserError.nestingLimitExceeded }
    }
}
