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
