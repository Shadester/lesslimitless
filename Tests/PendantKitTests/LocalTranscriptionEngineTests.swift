import Foundation
import XCTest
import Domain
@testable import PendantKit

final class LocalTranscriptionEngineTests: XCTestCase {
    func testWhisperCPPArgumentsAndRunnerInvocation() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let job = LocalTranscriptionJob.whisperCPP(executableURL: URL(fileURLWithPath: "/bin/true"), modelURL: URL(fileURLWithPath: "/tmp/model.bin"), audioURL: audio, additionalArguments: ["-l", "en"])
        let runner = MockRunner(output: jsonOutput)
        _ = try LocalTranscriptionEngine(runner: runner).transcribe(job)
        XCTAssertEqual(runner.executableURL, URL(fileURLWithPath: "/bin/true"))
        XCTAssertEqual(runner.arguments, ["-m", "/tmp/model.bin", "-f", audio.path, "-oj", "-l", "en"])
    }

    func testParsesWhisperTimestampedJSONAndProvenance() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let runner = MockRunner(output: jsonOutput)
        let result = try LocalTranscriptionEngine(runner: runner).transcribe(job(audio: audio))
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.segments.map(\.startTime), [0, 1.5])
        XCTAssertEqual(result.segments.map(\.endTime), [1.5, 3])
        XCTAssertEqual(result.provenance.arguments, ["-f", audio.path])
    }

    func testNonzeroTimeoutAndMalformedOutputAreReported() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: MockRunner(output: .init(exitStatus: 7, stdout: Data(), stderr: Data("bad model".utf8)))).transcribe(job(audio: audio))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .processFailed(exitStatus: 7, stderr: "bad model"))
        }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: MockRunner(error: .timedOut)).transcribe(job(audio: audio))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .timedOut)
        }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: MockRunner(output: .init(exitStatus: 0, stdout: Data("{}".utf8), stderr: Data()))).transcribe(job(audio: audio))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .malformedTranscript)
        }
    }

    func testRejectsInvalidExecutableAndAudioPathsBeforeRunning() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let runner = MockRunner(output: jsonOutput)
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: runner).transcribe(LocalTranscriptionJob(executableURL: URL(string: "https://example.com/whisper")!, audioURL: audio, arguments: []))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .invalidExecutable(URL(string: "https://example.com/whisper")!))
        }
        XCTAssertThrowsError(try LocalTranscriptionEngine(runner: runner).transcribe(LocalTranscriptionJob(executableURL: URL(fileURLWithPath: "/bin/true"), audioURL: URL(fileURLWithPath: "/missing.wav"), arguments: []))) {
            XCTAssertEqual($0 as? LocalTranscriptionError, .invalidAudio(URL(fileURLWithPath: "/missing.wav")))
        }
        XCTAssertNil(runner.arguments)
    }

    private var jsonOutput: LocalTranscriptionProcessOutput {
        LocalTranscriptionProcessOutput(exitStatus: 0, stdout: Data("{\"result\":{\"language\":\"en\",\"segments\":[{\"t0\":0,\"t1\":150,\"text\":\"hello\"},{\"t0\":150,\"t1\":300,\"text\":\"world\"}]}}".utf8), stderr: Data())
    }

    private func job(audio: URL) -> LocalTranscriptionJob {
        LocalTranscriptionJob(executableURL: URL(fileURLWithPath: "/bin/true"), audioURL: audio, arguments: ["-f", audio.path])
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTranscriptionEngineTests-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
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
