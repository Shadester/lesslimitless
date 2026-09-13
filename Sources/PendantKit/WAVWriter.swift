import Foundation

/// Pure PCM16 WAV encoding for locally decoded audio.
public enum WAVWriter {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidFormat
        case fileTooLarge
    }

    public static func pcm16Data(samples: [Float], sampleRate: Int = 16_000, channels: Int = 1) throws -> Data {
        guard sampleRate > 0, channels > 0, channels <= Int(UInt16.max), samples.count % channels == 0 else { throw Error.invalidFormat }
        let (ratePerChannel, didOverflowRate) = Int64(sampleRate).multipliedReportingOverflow(by: Int64(channels))
        let (byteRate, didOverflowByteRate) = ratePerChannel.multipliedReportingOverflow(by: 2)
        guard !didOverflowRate, !didOverflowByteRate,
              byteRate <= Int64(UInt32.max), Int64(channels) * 2 <= Int64(UInt16.max) else { throw Error.fileTooLarge }
        let payloadBytes = try checkedPayloadBytes(samples.count)
        var data = Data()
        data.reserveCapacity(44 + payloadBytes)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + payloadBytes), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(channels), to: &data)
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(byteRate), to: &data)
        appendLE(UInt16(channels * 2), to: &data)
        appendLE(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(payloadBytes), to: &data)
        for sample in samples {
            let value: Int16
            if !sample.isFinite || sample <= -1 { value = Int16.min }
            else if sample >= 1 { value = Int16.max }
            else { value = Int16((sample * 32767).rounded()) }
            appendLE(UInt16(bitPattern: value), to: &data)
        }
        return data
    }

    public static func writePCM16(samples: [Float], to url: URL, sampleRate: Int = 16_000, channels: Int = 1) throws {
        try pcm16Data(samples: samples, sampleRate: sampleRate, channels: channels).write(to: url, options: .atomic)
    }

    private static func checkedPayloadBytes(_ sampleCount: Int) throws -> Int {
        guard sampleCount <= (Int(UInt32.max) - 36) / 2 else { throw Error.fileTooLarge }
        return sampleCount * 2
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}
