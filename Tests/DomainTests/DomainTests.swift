import Foundation
import XCTest
@testable import Domain

final class DomainTests: XCTestCase {
    func testRecordingDurationNeverBecomesNegative() {
        let start = Date(timeIntervalSince1970: 1_000)
        let recording = Recording(
            title: "Clock correction",
            source: .systemAudio,
            startedAt: start,
            endedAt: start.addingTimeInterval(-10),
            status: .ready
        )

        XCTAssertEqual(recording.duration, 0)
    }

    func testTranscriptSegmentNormalizesInvalidBounds() {
        let segment = TranscriptSegment(startTime: -4, endTime: -10, text: "Hello")

        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 0)
        XCTAssertEqual(segment.duration, 0)
    }

    func testTranscriptSegmentNormalizesDecodedBounds() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","startTime":-5,"endTime":-8,"text":"Recovered"}"#
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 0)
    }

    func testJobProgressIsClampedAndTerminalJobsDoNotRestart() {
        let timestamp = Date(timeIntervalSince1970: 100)
        var job = ProcessingJob(kind: .transcription, progress: -1, createdAt: timestamp)
        XCTAssertEqual(job.progress, 0)

        job.updateProgress(1.4, at: timestamp.addingTimeInterval(2))
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(job.state, .running)

        job.state = .succeeded
        job.updateProgress(0.2)
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(job.state, .succeeded)
    }

    func testJobClampsDecodedProgressAndAttempts() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000002","kind":"transcription","state":"queued","progress":4,"attempts":-2,"createdAt":0,"updatedAt":0}"#
        let job = try JSONDecoder().decode(ProcessingJob.self, from: Data(json.utf8))
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(job.attempts, 0)
    }

    func testRetryClearsFailureAndCountsAttempt() {
        var job = ProcessingJob(
            kind: .pendantSync,
            state: .failed,
            progress: 0.6,
            attempts: 2,
            errorMessage: "Disconnected"
        )

        job.retry()

        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.progress, 0)
        XCTAssertEqual(job.attempts, 3)
        XCTAssertNil(job.errorMessage)
    }

    func testOnlyCompleteHashVerificationPermitsCleanup() {
        XCTAssertFalse(SyncVerification.pending.permitsDeviceCleanup)
        XCTAssertFalse(SyncVerification.verified(rawPageHash: "raw", audioHash: "").permitsDeviceCleanup)
        XCTAssertTrue(SyncVerification.verified(rawPageHash: "raw", audioHash: "audio").permitsDeviceCleanup)
    }

    func testAssociatedValueModelsRoundTripThroughCodable() throws {
        let original = Recording(
            title: "Pendant sample",
            source: .pendant(deviceName: "P-1"),
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            status: .processing,
            tags: ["sample"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
