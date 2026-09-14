import Foundation
import Domain
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct LocalTranscriptionProcessOutput: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool

    public init(exitStatus: Int32, stdout: Data, stderr: Data, stdoutWasTruncated: Bool = false, stderrWasTruncated: Bool = false) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutWasTruncated = stdoutWasTruncated
        self.stderrWasTruncated = stderrWasTruncated
    }
}

/// Allows callers to substitute a deterministic runner in tests. The executable
/// URL and arguments are kept separate, so implementations must not use a shell.
public protocol LocalTranscriptionProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        isCancelled: @escaping () -> Bool
    ) throws -> LocalTranscriptionProcessOutput
}

public enum LocalTranscriptionError: Error, Equatable, Sendable {
    case invalidExecutable(URL)
    case invalidAudio(URL)
    case invalidConfiguration
    case timedOut
    case cancelled
    case processFailed(exitStatus: Int32, stderr: String)
    case malformedTranscript
    case launchFailed(String)
}

public final class LocalTranscriptionEngine {
    private let runner: any LocalTranscriptionProcessRunning

    public init(runner: any LocalTranscriptionProcessRunning = FoundationLocalTranscriptionProcessRunner()) {
        self.runner = runner
    }

    public func transcribe(_ job: LocalTranscriptionJob, isCancelled: @escaping () -> Bool = { false }) throws -> LocalTranscriptionResult {
        try validate(job)
        if isCancelled() { throw LocalTranscriptionError.cancelled }
        let output = try runner.run(
            executableURL: job.executableURL.standardizedFileURL,
            arguments: job.arguments,
            timeout: job.timeout,
            maximumOutputBytes: job.maximumOutputBytes,
            isCancelled: isCancelled
        )
        if isCancelled() { throw LocalTranscriptionError.cancelled }
        guard output.exitStatus == 0 else {
            throw LocalTranscriptionError.processFailed(
                exitStatus: output.exitStatus,
                stderr: String(decoding: output.stderr, as: UTF8.self)
            )
        }

        let provenance = LocalTranscriptionProvenance(
            executableURL: job.executableURL.standardizedFileURL,
            audioURL: job.audioURL.standardizedFileURL,
            arguments: job.arguments,
            exitStatus: output.exitStatus,
            stdoutWasTruncated: output.stdoutWasTruncated,
            stderrWasTruncated: output.stderrWasTruncated
        )
        if !job.expectsTimestampedJSON {
            return LocalTranscriptionResult(text: String(decoding: output.stdout, as: UTF8.self), segments: [], language: nil, provenance: provenance)
        }
        let parsed = try Self.parseTimestampedJSON(output.stdout)
        return LocalTranscriptionResult(text: parsed.text, segments: parsed.segments, language: parsed.language, provenance: provenance)
    }

    private func validate(_ job: LocalTranscriptionJob) throws {
        guard job.timeout > 0, job.maximumOutputBytes > 0 else { throw LocalTranscriptionError.invalidConfiguration }
        try validateRegularFile(job.executableURL, executable: true, error: .invalidExecutable(job.executableURL))
        try validateRegularFile(job.audioURL, executable: false, error: .invalidAudio(job.audioURL))
    }

    private func validateRegularFile(_ url: URL, executable: Bool, error: LocalTranscriptionError) throws {
        guard url.isFileURL else { throw error }
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw error }
        if executable && !FileManager.default.isExecutableFile(atPath: resolved.path) { throw error }
        if !executable && !FileManager.default.isReadableFile(atPath: resolved.path) { throw error }
    }

    private static func parseTimestampedJSON(_ data: Data) throws -> (text: String, segments: [TranscriptSegment], language: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalTranscriptionError.malformedTranscript
        }
        let result = root["result"] as? [String: Any] ?? root
        let rawSegments = (result["segments"] as? [[String: Any]]) ?? (root["transcription"] as? [[String: Any]])
        guard let rawSegments else { throw LocalTranscriptionError.malformedTranscript }
        let segments = try rawSegments.map { item -> TranscriptSegment in
            guard let text = item["text"] as? String else { throw LocalTranscriptionError.malformedTranscript }
            let timestamps = item["timestamps"] as? [String: Any]
            guard let start = timestamp(item["start"] ?? item["t0"] ?? timestamps?["from"], centiseconds: item["t0"] != nil),
                  let end = timestamp(item["end"] ?? item["t1"] ?? timestamps?["to"], centiseconds: item["t1"] != nil), end >= start else {
                throw LocalTranscriptionError.malformedTranscript
            }
            return TranscriptSegment(startTime: start, endTime: end, text: text)
        }
        let text = (result["text"] as? String) ?? segments.map(\.text).joined(separator: " ")
        return (text, segments, (result["language"] as? String) ?? (root["language"] as? String))
    }

    private static func timestamp(_ value: Any?, centiseconds: Bool) -> TimeInterval? {
        if let number = value as? NSNumber { return centiseconds ? number.doubleValue / 100 : number.doubleValue }
        guard let string = value as? String else { return nil }
        if let seconds = Double(string) { return seconds }
        let pieces = string.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard pieces.count == 3, let hours = Double(pieces[0]), let minutes = Double(pieces[1]), let seconds = Double(pieces[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

public final class FoundationLocalTranscriptionProcessRunner: LocalTranscriptionProcessRunning {
    public init() {}

    public func run(executableURL: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int, isCancelled: @escaping () -> Bool) throws -> LocalTranscriptionProcessOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let capturedStdout = BoundedData(limit: maximumOutputBytes)
        let capturedStderr = BoundedData(limit: maximumOutputBytes)
        stdout.fileHandleForReading.readabilityHandler = { capturedStdout.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { capturedStderr.append($0.availableData) }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw LocalTranscriptionError.launchFailed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if isCancelled() {
                stop(process)
                throw LocalTranscriptionError.cancelled
            }
            if Date() >= deadline {
                stop(process)
                throw LocalTranscriptionError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        capturedStdout.append(stdout.fileHandleForReading.readDataToEndOfFile())
        capturedStderr.append(stderr.fileHandleForReading.readDataToEndOfFile())
        return LocalTranscriptionProcessOutput(exitStatus: process.terminationStatus, stdout: capturedStdout.data, stderr: capturedStderr.data, stdoutWasTruncated: capturedStdout.wasTruncated, stderrWasTruncated: capturedStderr.wasTruncated)
    }

    private func stop(_ process: Process) {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < graceDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

private final class BoundedData: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private(set) var data = Data()
    private(set) var wasTruncated = false
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else { wasTruncated = wasTruncated || !chunk.isEmpty; return }
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { wasTruncated = true }
    }
}
