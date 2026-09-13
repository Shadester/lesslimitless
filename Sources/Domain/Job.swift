import Foundation

public enum JobKind: String, Codable, CaseIterable, Sendable {
    case pendantSync
    case audioFinalization
    case transcription
    case export
}

public enum JobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

public struct ProcessingJob: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: JobKind
    public var state: JobState
    public private(set) var progress: Double
    public private(set) var attempts: Int
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: JobKind,
        state: JobState = .queued,
        progress: Double = 0,
        attempts: Int = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = min(max(progress, 0), 1)
        self.attempts = max(0, attempts)
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, state, progress, attempts, errorMessage, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            kind: try values.decode(JobKind.self, forKey: .kind),
            state: try values.decode(JobState.self, forKey: .state),
            progress: try values.decode(Double.self, forKey: .progress),
            attempts: try values.decode(Int.self, forKey: .attempts),
            errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }

    public mutating func updateProgress(_ value: Double, at date: Date = Date()) {
        guard !state.isTerminal else { return }
        progress = min(max(value, 0), 1)
        state = .running
        updatedAt = date
    }

    public mutating func retry(at date: Date = Date()) {
        guard state == .failed || state == .cancelled else { return }
        attempts += 1
        progress = 0
        errorMessage = nil
        state = .queued
        updatedAt = date
    }
}
