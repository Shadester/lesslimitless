import Foundation

public enum PendantSessionArchiveError: Error, Equatable, Sendable {
    case emptyEligibleOpus(PendantSessionManifest)
}

/// Bridges pure session assembly to a write-only raw Opus archive. Callers own
/// the session identifier; this coordinator never derives it from untrusted
/// peripheral text and never alters raw flash-page storage.
public struct PendantSessionArchiver {
    private let writer: RawOpusArchiveWriter

    public init(rootURL: URL) throws {
        writer = try RawOpusArchiveWriter(rootURL: rootURL)
    }

    @discardableResult
    public func archive(_ session: PendantSessionManifest, sessionID: String) throws -> RawOpusArchive {
        var bytes = Data()
        for contribution in session.contributions {
            for frameGroup in contribution.encodedOpusBytes {
                bytes.append(frameGroup)
            }
        }
        guard !bytes.isEmpty else { throw PendantSessionArchiveError.emptyEligibleOpus(session) }
        return try writer.write(opusData: bytes, sessionID: sessionID)
    }
}
