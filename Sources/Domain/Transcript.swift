import Foundation

public enum TranscriptStatus: String, Codable, CaseIterable, Sendable {
    case notRequested
    case queued
    case transcribing
    case complete
    case failed
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var text: String
    public var speaker: String?

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        speaker: String? = nil
    ) {
        self.id = id
        self.startTime = max(0, startTime)
        self.endTime = max(max(0, startTime), endTime)
        self.text = text
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, text, speaker
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            startTime: try values.decode(TimeInterval.self, forKey: .startTime),
            endTime: try values.decode(TimeInterval.self, forKey: .endTime),
            text: try values.decode(String.self, forKey: .text),
            speaker: try values.decodeIfPresent(String.self, forKey: .speaker)
        )
    }

    public var duration: TimeInterval { endTime - startTime }
}

extension Array where Element == TranscriptSegment {
    /// Collapses runs of `minimumRunLength`+ consecutive segments whose text is the
    /// same (ignoring case/whitespace/trailing punctuation) into a single segment
    /// spanning the run. whisper.cpp occasionally locks onto one phrase and repeats
    /// it verbatim for dozens of segments in a row (a decoder hallucination loop,
    /// not real speech) — real repeated phrases in speech don't chain that many
    /// times back-to-back, so a long run is a reliable signal of the bug rather
    /// than content worth keeping duplicated.
    public func collapsingHallucinatedRepeats(minimumRunLength: Int = 3) -> [TranscriptSegment] {
        guard count >= minimumRunLength else { return self }
        var result: [TranscriptSegment] = []
        var runStart = 0
        for i in 1...count {
            let continuesRun = i < count && Self.normalized(self[i].text) == Self.normalized(self[runStart].text)
            if !continuesRun {
                if i - runStart >= minimumRunLength {
                    result.append(TranscriptSegment(startTime: self[runStart].startTime, endTime: self[i - 1].endTime, text: self[runStart].text, speaker: self[runStart].speaker))
                } else {
                    result.append(contentsOf: self[runStart..<i])
                }
                runStart = i
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?").union(.whitespacesAndNewlines)).lowercased()
    }
}

public struct Transcript: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public var engine: String
    public var model: String
    public var language: String?
    public var status: TranscriptStatus
    public var segments: [TranscriptSegment]

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        engine: String,
        model: String,
        language: String? = nil,
        status: TranscriptStatus,
        segments: [TranscriptSegment] = []
    ) {
        self.id = id
        self.recordingID = recordingID
        self.engine = engine
        self.model = model
        self.language = language
        self.status = status
        self.segments = segments
    }
}
