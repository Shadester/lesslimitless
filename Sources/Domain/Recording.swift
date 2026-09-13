import Foundation

public enum RecordingSource: Codable, Hashable, Sendable {
    case pendant(deviceName: String)
    case macApplication(name: String)
    case systemAudio
    case imported

    public var displayName: String {
        switch self {
        case .pendant(let deviceName): "Pendant · \(deviceName)"
        case .macApplication(let name): "Mac · \(name)"
        case .systemAudio: "Mac · System Audio"
        case .imported: "Imported"
        }
    }
}

public enum RecordingStatus: String, Codable, CaseIterable, Sendable {
    case recording
    case paused
    case processing
    case ready
    case failed
}

public struct Recording: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var source: RecordingSource
    public var startedAt: Date
    public var endedAt: Date?
    public var status: RecordingStatus
    public var note: String
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        source: RecordingSource,
        startedAt: Date,
        endedAt: Date? = nil,
        status: RecordingStatus,
        note: String = "",
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.note = note
        self.tags = tags
    }

    public var duration: TimeInterval {
        max(0, (endedAt ?? startedAt).timeIntervalSince(startedAt))
    }
}
