import Foundation

public enum SyncVerification: Codable, Hashable, Sendable {
    case pending
    case validating
    case verified(rawPageHash: String, audioHash: String)
    case failed(reason: String)

    /// Cleanup is safe only after both independently computed artifacts are recorded.
    public var permitsDeviceCleanup: Bool {
        guard case .verified(let rawPageHash, let audioHash) = self else { return false }
        return !rawPageHash.isEmpty && !audioHash.isEmpty
    }
}

public enum PendantConnectionState: String, Codable, CaseIterable, Sendable {
    case unavailable
    case disconnected
    case scanning
    case connecting
    case connected
}
