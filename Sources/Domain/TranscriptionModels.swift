import Foundation

/// A local executable transcription request. `arguments` are passed directly to
/// `Process`; no shell, command string, or network endpoint is involved.
public struct LocalTranscriptionJob: Sendable, Equatable {
    public let executableURL: URL
    public let audioURL: URL
    public let arguments: [String]
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int
    public let expectsTimestampedJSON: Bool

    public init(
        executableURL: URL,
        audioURL: URL,
        arguments: [String],
        timeout: TimeInterval = 300,
        maximumOutputBytes: Int = 1_048_576,
        expectsTimestampedJSON: Bool = true
    ) {
        self.executableURL = executableURL
        self.audioURL = audioURL
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.expectsTimestampedJSON = expectsTimestampedJSON
    }

    /// Arguments for a whisper.cpp-compatible command line.
    public static func whisperCPP(
        executableURL: URL,
        modelURL: URL,
        audioURL: URL,
        additionalArguments: [String] = [],
        timeout: TimeInterval = 300,
        maximumOutputBytes: Int = 1_048_576
    ) -> LocalTranscriptionJob {
        LocalTranscriptionJob(
            executableURL: executableURL,
            audioURL: audioURL,
            arguments: ["-m", modelURL.path, "-f", audioURL.path, "-oj"] + additionalArguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            expectsTimestampedJSON: true
        )
    }
}

public struct LocalTranscriptionProvenance: Sendable, Equatable {
    public let executableURL: URL
    public let audioURL: URL
    public let arguments: [String]
    public let exitStatus: Int32
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool

    public init(executableURL: URL, audioURL: URL, arguments: [String], exitStatus: Int32, stdoutWasTruncated: Bool, stderrWasTruncated: Bool) {
        self.executableURL = executableURL
        self.audioURL = audioURL
        self.arguments = arguments
        self.exitStatus = exitStatus
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
    }
}

public struct LocalTranscriptionResult: Sendable, Equatable {
    public let text: String
    public let segments: [TranscriptSegment]
    public let language: String?
    public let provenance: LocalTranscriptionProvenance

    public init(text: String, segments: [TranscriptSegment], language: String?, provenance: LocalTranscriptionProvenance) {
        self.text = text
        self.segments = segments
        self.language = language
        self.provenance = provenance
    }
}
