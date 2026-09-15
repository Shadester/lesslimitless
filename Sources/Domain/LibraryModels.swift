import Foundation

/// The lifecycle of locally derived recording data. No processing implementation
/// is implied by these values.
public enum LibraryProcessingState: String, Codable, CaseIterable, Hashable, Sendable {
    case captured
    case queued
    case processing
    case ready
    case failed
}

public struct LibraryGeneratedArtifact: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: String
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}

/// Complete durable metadata for a recording. `mediaRelativePath`, when set,
/// is always relative to the library root and is validated by `LocalLibraryStore`.
public struct LibraryRecording: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var source: RecordingSource
    public var mediaRelativePath: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var processingState: LibraryProcessingState
    public var notes: String
    public var tags: [String]
    public var transcriptSegments: [TranscriptSegment]
    public var generatedArtifacts: [LibraryGeneratedArtifact]

    public init(
        id: UUID = UUID(),
        title: String,
        source: RecordingSource,
        mediaRelativePath: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        processingState: LibraryProcessingState = .captured,
        notes: String = "",
        tags: [String] = [],
        transcriptSegments: [TranscriptSegment] = [],
        generatedArtifacts: [LibraryGeneratedArtifact] = []
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.mediaRelativePath = mediaRelativePath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.processingState = processingState
        self.notes = notes
        self.tags = tags
        self.transcriptSegments = transcriptSegments
        self.generatedArtifacts = generatedArtifacts
    }

    /// Span from first to last recorded page timestamp; an approximation of audio
    /// length, not a decode of the underlying media file. For a merged pendant
    /// encounter this includes silence between bursts, so it can run noticeably
    /// longer than the actual audio (~37% longer on a measured day of wear).
    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// Summary text when one has been generated, else the opening of the transcript.
    /// Used by list rows to lead with what was said rather than recording metadata.
    public var semanticPreview: String? {
        if let summary = generatedArtifacts.last(where: { $0.kind.hasPrefix("summary") }) {
            return summary.text
        }
        guard !transcriptSegments.isEmpty else { return nil }
        return transcriptSegments.map(\.text).joined(separator: " ")
    }
}

public enum LibrarySearchField: String, Codable, CaseIterable, Hashable, Sendable {
    case title
    case notes
    case tags
    case transcript
    case generatedArtifact
}

public struct LibrarySearchResult: Hashable, Sendable {
    public let recording: LibraryRecording
    public let score: Int
    public let matchedFields: Set<LibrarySearchField>

    public init(recording: LibraryRecording, score: Int, matchedFields: Set<LibrarySearchField>) {
        self.recording = recording
        self.score = score
        self.matchedFields = matchedFields
    }
}
