import Foundation
import XCTest
import Domain
@testable import PendantKit

final class LocalTranscriptionEngineTests: XCTestCase {
    func testWhisperCPPArgumentsAndRunnerInvocation() throws {
        let audio = try makeAudio()
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: executable) }
        let job = LocalTranscriptionJob.whisperCPP(executableURL: executable, modelURL: URL(fileURLWithPath: "/tmp/model.bin"), audioURL: audio, additionalArguments: ["-l", "en"])
        let runner = MockRunner(output: jsonOutput)
        _ = try LocalTranscriptionEngine(runner: runner).transcribe(job)
        XCTAssertEqual(runner.executableURL, executable)
        XCTAssertEqual(runner.arguments, ["-m", "/tmp/model.bin", "-f", audio.path, "-oj", "-l", "en"])
    }

    func testParsesWhisperTimestampedJSONAndProvenance() throws {
        let audio = try makeAudio()
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: executable) }
        let runner = MockRunner(output: jsonOutput)
        let result = try LocalTranscriptionEngine(runner: runner).transcribe(job(audio: audio, executable: executable))
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.segments.map(\.startTime), [0, 1.5])
        XCTAssertEqual(result.segments.map(\.endTime), [1.5, 3])
    }

    func testNonzeroTimeoutAndMalformedOutputAreReported() throws {
        let audio = try makeAudio()
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: executable) }
        let job = job(audio: audio, executable: executable)
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: MockRunner(output: .init(exitStatus: 7, stdout: Data(), stderr: Data("bad model".utf8)))).transcribe(job)) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .processFailed(exitStatus: 7, stderr: "bad model"))
        }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: MockRunner(error: .timedOut)).transcribe(job)) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .timedOut)
        }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: MockRunner(output: .init(exitStatus: 0, stdout: Data("{}".utf8), stderr: Data()))).transcribe(job)) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .malformedTranscript)
        }
    }

    func testRejectsInvalidExecutableAndAudioPathsBeforeRunning() throws {
        let audio = try makeAudio()
        let executable = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: executable) }
        let runner = MockRunner(output: jsonOutput)
        let remote = URL(string: "https://example.com/whisper")!
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: runner).transcribe(LocalTranscriptionJob(executableURL: remote, audioURL: audio, arguments: []))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .invalidExecutable(remote))
        }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: runner).transcribe(LocalTranscriptionJob(executableURL: executable, audioURL: URL(fileURLWithPath: "/missing.wav"), arguments: []))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .invalidAudio(URL(fileURLWithPath: "/missing.wav")))
        }
        XCTAssertNil(runner.arguments)
    }

    private var jsonOutput: LocalTranscriptionProcessOutput {
        LocalTranscriptionProcessOutput(exitStatus: 0, stdout: Data("{\"result\":{\"language\":\"en\",\"segments\":[{\"t0\":0,\"t1\":150,\"text\":\"hello\"},{\"t0\":150,\"t1\":300,\"text\":\"world\"}]}}".utf8), stderr: Data())
    }

    private func job(audio: URL, executable: URL) -> LocalTranscriptionJob {
        LocalTranscriptionJob(executableURL: executable, audioURL: audio, arguments: ["-f", audio.path])
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTranscriptionEngineTests-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
        return url
    }

    private func makeExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTranscriptionEngineTests-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private final class MockRunner: LocalTranscriptionProcessRunning {
    let output: LocalTranscriptionProcessOutput?
    let error: LocalTranscriptionError?
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?

    init(output: LocalTranscriptionProcessOutput) { self.output = output; self.error = nil }
    init(error: LocalTranscriptionError) { self.output = nil; self.error = error }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int, isCancelled: @escaping () -> Bool) throws -> LocalTranscriptionProcessOutput {
        self.executableURL = executableURL
        self.arguments = arguments
        if let error { throw error }
        return output!
    }
}
