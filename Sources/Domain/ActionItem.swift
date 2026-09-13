import Foundation

public enum ActionItemState: String, Codable, CaseIterable, Sendable {
    case open
    case completed
}

public struct ActionItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var owner: String?
    public var dueDate: Date?
    public var state: ActionItemState
    public let recordingID: UUID?

    public init(
        id: UUID = UUID(),
        text: String,
        owner: String? = nil,
        dueDate: Date? = nil,
        state: ActionItemState = .open,
        recordingID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.owner = owner
        self.dueDate = dueDate
        self.state = state
        self.recordingID = recordingID
    }
}
