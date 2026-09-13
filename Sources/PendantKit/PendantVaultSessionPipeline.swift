import Crypto
import Foundation

/// A page that could not safely contribute to a session archive.
public enum PendantVaultSessionPageFailure: Equatable, Sendable {
    case failedRecord(PendantPageIdentity, reason: String)
    case rawPageUnavailable(PendantPageIdentity)
    case rawPageHashMismatch(PendantPageIdentity, expected: String, actual: String)
    case parseFailed(PendantPageIdentity, reason: String)
    case quarantinedIncompleteRecording(PendantPageIdentity)

    public var identity: PendantPageIdentity {
        switch self {
        case .failedRecord(let identity, _), .rawPageUnavailable(let identity),
             .rawPageHashMismatch(let identity, _, _), .parseFailed(let identity, _),
             .quarantinedIncompleteRecording(let identity):
            return identity
        }
    }
}

public struct PendantArchivedSession: Equatable, Sendable {
    public let manifestIndex: Int
    public let archiveID: String
    public let archive: RawOpusArchive

    public init(manifestIndex: Int, archiveID: String, archive: RawOpusArchive) {
        self.manifestIndex = manifestIndex
        self.archiveID = archiveID
        self.archive = archive
    }
}

public struct PendantSkippedEmptySession: Equatable, Sendable {
    public let manifestIndex: Int
    public let archiveID: String

    public init(manifestIndex: Int, archiveID: String) {
        self.manifestIndex = manifestIndex
        self.archiveID = archiveID
    }
}

/// The non-destructive result of loading a raw page vault and archiving its usable sessions.
public struct PendantVaultSessionPipelineReport: Equatable, Sendable {
    public let loadedPageIdentities: [PendantPageIdentity]
    public let failedPages: [PendantVaultSessionPageFailure]
    public let diagnostics: [PendantSessionDiagnostic]
    public let archivedSessions: [PendantArchivedSession]
    public let skippedEmptySessions: [PendantSkippedEmptySession]

    public init(
        loadedPageIdentities: [PendantPageIdentity],
        failedPages: [PendantVaultSessionPageFailure],
        diagnostics: [PendantSessionDiagnostic],
        archivedSessions: [PendantArchivedSession],
        skippedEmptySessions: [PendantSkippedEmptySession]
    ) {
        self.loadedPageIdentities = loadedPageIdentities
        self.failedPages = failedPages
        self.diagnostics = diagnostics
        self.archivedSessions = archivedSessions
        self.skippedEmptySessions = skippedEmptySessions
    }
}

/// Loads persisted raw pages, verifies them again, and creates immutable Opus archives.
/// It never acknowledges, deletes, or otherwise modifies the raw page vault.
public struct PendantVaultSessionPipeline {
    private let ledger: PendantPageLedger
    private let parser: FlashPageParser

    public init(ledger: PendantPageLedger, parser: FlashPageParser) {
        self.ledger = ledger
        self.parser = parser
    }

    public init(ledger: PendantPageLedger) throws {
        self.init(ledger: ledger, parser: try FlashPageParser())
    }

    public init(vaultRootURL: URL, parser: FlashPageParser) throws {
        self.init(ledger: try PendantPageLedger(rootURL: vaultRootURL), parser: parser)
    }

    public init(vaultRootURL: URL) throws {
        try self.init(vaultRootURL: vaultRootURL, parser: FlashPageParser())
    }

    /// Builds archives below the caller-owned root. Failed ledger records are reported and excluded;
    /// received and verified records are both eligible after their raw hash is revalidated.
    public func archive(to archiveRootURL: URL) throws -> PendantVaultSessionPipelineReport {
        var loaded: [PendantSessionPage] = []
        var failures: [PendantVaultSessionPageFailure] = []

        for record in ledger.records {
            let identity = record.identity
            if record.state == .failed {
                let reason: String
                if case .failed(let value) = record.verification {
                    reason = value
                } else {
                    reason = "ledger record is failed"
                }
                failures.append(.failedRecord(identity, reason: reason))
                continue
            }

            let rawPage: Data
            do {
                rawPage = try Data(contentsOf: ledger.rawPageURL(for: identity))
            } catch {
                failures.append(.rawPageUnavailable(identity))
                continue
            }
            let actualHash = PendantPageLedger.sha256Hex(rawPage)
            guard actualHash == record.rawPageHash else {
                failures.append(.rawPageHashMismatch(identity, expected: record.rawPageHash, actual: actualHash))
                continue
            }
            do {
                loaded.append(PendantSessionPage(identity: identity, summary: try parser.decode(rawPage)))
            } catch {
                failures.append(.parseFailed(identity, reason: String(describing: error)))
            }
        }

        let incompleteGroups = Set(failures.map { GroupKey($0.identity) })
        if !incompleteGroups.isEmpty {
            let quarantined = loaded.filter { incompleteGroups.contains(GroupKey($0.identity)) }
            loaded.removeAll { incompleteGroups.contains(GroupKey($0.identity)) }
            failures.append(contentsOf: quarantined.map { .quarantinedIncompleteRecording($0.identity) })
        }

        let assembly = PendantSessionAssembler().assemble(loaded)
        let archiver = try PendantSessionArchiver(rootURL: archiveRootURL)
        var archived: [PendantArchivedSession] = []
        var skipped: [PendantSkippedEmptySession] = []
        for session in assembly.sessions {
            let archiveID = try Self.archiveID(for: session, ledger: ledger)
            do {
                let archive = try archiver.archive(session, sessionID: archiveID)
                archived.append(PendantArchivedSession(manifestIndex: session.index, archiveID: archiveID, archive: archive))
            } catch PendantSessionArchiveError.emptyEligibleOpus {
                skipped.append(PendantSkippedEmptySession(manifestIndex: session.index, archiveID: archiveID))
            }
        }
        return PendantVaultSessionPipelineReport(
            loadedPageIdentities: loaded.map(\.identity),
            failedPages: failures,
            diagnostics: assembly.diagnostics,
            archivedSessions: archived,
            skippedEmptySessions: skipped
        )
    }

    /// A safe archive name derived from every source page identity and raw hash.
    /// A later sync that adds pages receives a different immutable archive ID.
    public static func archiveID(deviceID: String, sessionID: String, runID: String, manifestIndex: Int) -> String {
        let source = "\(deviceID)\u{1F}\(sessionID)\u{1F}\(runID)\u{1F}\(manifestIndex)"
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pendant-\(hash.prefix(24))"
    }

    private static func archiveID(for session: PendantSessionManifest, ledger: PendantPageLedger) throws -> String {
        let source = try session.contributions.map { contribution -> String in
            guard let record = ledger.record(for: contribution.identity) else {
                throw PendantPageLedgerError.missingPage(contribution.identity)
            }
            let identity = contribution.identity
            return "\(identity.deviceID)\u{1F}\(identity.sessionID)\u{1F}\(identity.runID)\u{1F}\(identity.sequence)\u{1F}\(identity.pageIndex)\u{1F}\(record.rawPageHash)"
        }.joined(separator: "\u{1E}")
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pendant-\(hash.prefix(24))"
    }

    private struct GroupKey: Hashable {
        let deviceID: String
        let sessionID: String
        let runID: String

        init(_ identity: PendantPageIdentity) {
            deviceID = identity.deviceID
            sessionID = identity.sessionID
            runID = identity.runID
        }
    }
}
