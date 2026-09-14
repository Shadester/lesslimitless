import Foundation
import XCTest
@testable import PendantKit

final class PendantSessionAssemblerTests: XCTestCase {
    func testStartAndStopCreateExplicitSessionBoundaries() {
        let first = page(1, timestamp: 1_000, audio: audio(start: true, bytes: [1]))
        let second = page(2, timestamp: 2_000, audio: audio(stop: true, bytes: [2]))
        let result = PendantSessionAssembler().assemble([second, first])

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].contributions.map(\.identity.sequence), [1, 2])
        XCTAssertEqual(result.sessions[0].openingBoundary, .recordingStarted(first.identity))
        XCTAssertEqual(result.sessions[0].closingBoundary, .recordingStopped(second.identity))
    }

    func testFiveMinuteGapSplitsSessions() {
        let first = page(1, timestamp: 1_000, audio: audio(bytes: [1]))
        let second = page(2, timestamp: 301_001, audio: audio(bytes: [2]))
        let result = PendantSessionAssembler().assemble([first, second])

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions[0].closingBoundary, .timestampGap(previous: first.identity, next: second.identity))
        XCTAssertEqual(result.sessions[1].openingBoundary, .timestampGap(previous: first.identity, next: second.identity))
    }

    func testOrdersByTimestampThenSequenceAndIndex() {
        let late = page(9, index: 2, timestamp: 2_000, audio: audio(bytes: [9]))
        let tiedLater = page(3, index: 2, timestamp: 1_000, audio: audio(bytes: [3]))
        let tiedFirst = page(3, index: 1, timestamp: 1_000, audio: audio(bytes: [1]))
        let result = PendantSessionAssembler().assemble([late, tiedLater, tiedFirst])

        XCTAssertEqual(result.sessions[0].contributions.map(\.encodedOpusBytes), [[Data([1])], [Data([3])], [Data([9])]])
    }

    func testMissingTimestampIsRetainedDiagnosedAndExplicitBoundariesStillSplit() {
        let stopped = page(1, timestamp: nil, audio: audio(stop: true, bytes: [1]))
        let started = page(2, timestamp: nil, audio: audio(start: true, bytes: [2]))
        let result = PendantSessionAssembler().assemble([started, stopped])

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.flatMap(\.contributions).count, 2)
        XCTAssertTrue(result.diagnostics.contains(.missingTimestamp(stopped.identity)))
        XCTAssertTrue(result.diagnostics.contains(.missingTimestamp(started.identity)))
    }

    func testMixedTimestampGroupUsesSequenceOrder() {
        let startWithoutTimestamp = page(1, timestamp: nil, audio: audio(start: true, bytes: [1]))
        let stopWithTimestamp = page(2, timestamp: 9_999, audio: audio(stop: true, bytes: [2]))
        let result = PendantSessionAssembler().assemble([stopWithTimestamp, startWithoutTimestamp])

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].contributions.map(\.identity.sequence), [1, 2])
        XCTAssertEqual(result.sessions[0].openingBoundary, .recordingStarted(startWithoutTimestamp.identity))
        XCTAssertEqual(result.sessions[0].closingBoundary, .recordingStopped(stopWithTimestamp.identity))
    }

    func testExcludesPCMNonOpusAndEncryptedAudio() {
        let pcmOnly = page(1, timestamp: 1, audio: audio(codecType: 2, bytes: nil, pcm: Data([7])))
        let nonOpus = page(2, timestamp: 2, audio: audio(codecType: 9, bytes: [8]))
        let encrypted = page(3, timestamp: 3, audio: audio(bytes: [9], encrypted: true))
        let result = PendantSessionAssembler().assemble([pcmOnly, nonOpus, encrypted])

        XCTAssertEqual(result.sessions[0].contributions.map(\.encodedOpusBytes), [[], [], []])
        XCTAssertTrue(result.diagnostics.contains(.unsupportedCodec(nonOpus.identity, codecType: 9)))
        XCTAssertTrue(result.diagnostics.contains(.encryptedAudioUnavailable(encrypted.identity)))
    }

    func testRequiresExactlyOneOpusFramePerEncodedPacket() {
        let missingCodec = page(1, timestamp: 1, audio: audio(codecType: nil, bytes: [1]))
        let missingFrames = page(2, timestamp: 2, audio: audio(bytes: [2], numFrames: nil))
        let zeroFrames = page(3, timestamp: 3, audio: audio(bytes: [3], numFrames: 0))
        let multipleFrames = page(4, timestamp: 4, audio: audio(bytes: [4], numFrames: 2))
        let result = PendantSessionAssembler().assemble([missingCodec, missingFrames, zeroFrames, multipleFrames])

        XCTAssertEqual(result.sessions[0].contributions.map(\.encodedOpusBytes), [[Data([1])], [], [], []])
        XCTAssertTrue(result.diagnostics.contains(.invalidOpusFrameCount(missingFrames.identity, numFrames: nil)))
        XCTAssertTrue(result.diagnostics.contains(.invalidOpusFrameCount(zeroFrames.identity, numFrames: 0)))
        XCTAssertTrue(result.diagnostics.contains(.invalidOpusFrameCount(multipleFrames.identity, numFrames: 2)))
    }

    private func page(_ sequence: Int, index: Int = 0, timestamp: UInt64?, audio: FlashPageAudio) -> PendantSessionPage {
        PendantSessionPage(
            identity: PendantPageIdentity(deviceID: "device", sessionID: "session", runID: "run", sequence: sequence, pageIndex: index),
            summary: FlashPageSummary(timestamp: timestamp, bootUptime: nil, chunks: [FlashPageChunk(timeOffset: nil, audioData: audio)])
        )
    }

    private func audio(start: Bool = false, stop: Bool = false, codecType: UInt64? = 1, bytes: [UInt8]? = nil, pcm: Data? = nil, encrypted: Bool = false, numFrames: UInt64? = 1) -> FlashPageAudio {
        FlashPageAudio(
            pcmOmni: pcm, pcmDirectional: nil, pcmBeamforming: nil,
            codecBeamforming: bytes.map { Data($0) }, codecManualBeamforming: nil, pcmManualBeamforming: nil,
            didStartRecording: start, didStopRecording: stop, codecType: codecType,
            numFrames: numFrames, degreeArrival: nil, hasEncryptedCodecPayload: encrypted
        )
    }
}
