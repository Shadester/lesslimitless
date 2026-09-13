import Crypto
import Domain
import Foundation

/// A stable identifier for one raw page received from a pendant.
public struct PendantPageIdentity: Codable, Hashable, Sendable {
    public let deviceID: String
    public let sessionID: String
    public let runID: String
    public let sequence: Int
    public let pageIndex: Int

    public init(deviceID: String, sessionID: String, runID: String, sequence: Int, pageIndex: Int) {
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.runID = runID
        self.sequence = sequence
        self.pageIndex = pageIndex
    }
}

public enum PendantPageState: String, Codable, Hashable, Sendable {
    case received
    case verified
    case failed
}

public struct PendantPageRecord: Codable, Hashable, Sendable {
    public let identity: PendantPageIdentity
    public let rawPageHash: String
    public let receivedAt: Date
    public var state: PendantPageState
    public var verification: SyncVerification

    public var permitsDeviceCleanup: Bool {
        state == .verified && verification.permitsDeviceCleanup
    }
}

public enum PendantPageIngestResult: Equatable, Sendable {
    case stored(PendantPageRecord)
    case duplicate(PendantPageRecord)
}

public enum PendantPageLedgerError: Error, Equatable, Sendable {
    case unsafeIdentifier(String)
    case invalidSequence
    case invalidPageIndex
    case payloadCollision(identity: PendantPageIdentity, existingHash: String, incomingHash: String)
    case rawPageHashMismatch(expected: String, supplied: String)
    case missingPage(PendantPageIdentity)
    case corruptRawPage(PendantPageIdentity)
    case invalidLedger
}

/// A dependency-free, append-only vault for raw pendant pages. It deliberately has no ACK or deletion API.
public final class PendantPageLedger {
    private struct Document: Codable {
        let version: Int
        var records: [PendantPageRecord]
    }

    private let rootURL: URL
    private let rawPagesURL: URL
    private let ledgerURL: URL
    private let lock = NSLock()
    private var recordsByIdentity: [PendantPageIdentity: PendantPageRecord]

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.rawPagesURL = self.rootURL.appendingPathComponent("raw-pages", isDirectory: true)
        self.ledgerURL = self.rootURL.appendingPathComponent("pendant-page-ledger.json")
        try FileManager.default.createDirectory(at: self.rawPagesURL, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
            self.recordsByIdentity = [:]
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: Data(contentsOf: ledgerURL))
            guard document.version == 1 else { throw PendantPageLedgerError.invalidLedger }
            var loaded: [PendantPageIdentity: PendantPageRecord] = [:]
            for record in document.records {
                try Self.validate(record.identity)
                guard loaded[record.identity] == nil else { throw PendantPageLedgerError.invalidLedger }
                loaded[record.identity] = record
            }
            self.recordsByIdentity = loaded
        } catch let error as PendantPageLedgerError {
            throw error
        } catch {
            throw PendantPageLedgerError.invalidLedger
        }
    }

    public convenience init(root: URL) throws {
        try self.init(rootURL: root)
    }

    public var records: [PendantPageRecord] {
        lock.lock(); defer { lock.unlock() }
        return recordsByIdentity.values.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func record(for identity: PendantPageIdentity) -> PendantPageRecord? {
        lock.lock(); defer { lock.unlock() }
        return recordsByIdentity[identity]
    }

    public func rawPageURL(for identity: PendantPageIdentity) throws -> URL {
        try Self.validate(identity)
        return rawURL(for: identity)
    }

    @discardableResult
    public func ingest(_ payload: Data, for identity: PendantPageIdentity, receivedAt: Date = Date()) throws -> PendantPageIngestResult {
        try Self.validate(identity)
        let hash = Self.sha256Hex(payload)
        lock.lock(); defer { lock.unlock() }

        if let existing = recordsByIdentity[identity] {
            guard existing.rawPageHash == hash else {
                throw PendantPageLedgerError.payloadCollision(identity: identity, existingHash: existing.rawPageHash, incomingHash: hash)
            }
            try ensureRawPage(payload, identity: identity, hash: hash)
            return .duplicate(existing)
        }

        try ensureRawPage(payload, identity: identity, hash: hash)
        let record = PendantPageRecord(identity: identity, rawPageHash: hash, receivedAt: receivedAt, state: .received, verification: .pending)
        recordsByIdentity[identity] = record
        do {
            try persist()
        } catch {
            recordsByIdentity.removeValue(forKey: identity)
            throw error
        }
        return .stored(record)
    }

    public func markVerified(_ identity: PendantPageIdentity, rawPageHash: String, audioHash: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = recordsByIdentity[identity] else { throw PendantPageLedgerError.missingPage(identity) }
        guard record.rawPageHash == rawPageHash else {
            throw PendantPageLedgerError.rawPageHashMismatch(expected: record.rawPageHash, supplied: rawPageHash)
        }
        record.state = .verified
        record.verification = .verified(rawPageHash: rawPageHash, audioHash: audioHash)
        try replaceAndPersist(record)
    }

    public func markFailed(_ identity: PendantPageIdentity, reason: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = recordsByIdentity[identity] else { throw PendantPageLedgerError.missingPage(identity) }
        record.state = .failed
        record.verification = .failed(reason: reason)
        try replaceAndPersist(record)
    }

    public func permitsDeviceCleanup(for identity: PendantPageIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recordsByIdentity[identity]?.permitsDeviceCleanup ?? false
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func ensureRawPage(_ payload: Data, identity: PendantPageIdentity, hash: String) throws {
        let url = rawURL(for: identity)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard Self.sha256Hex(existing) == hash else { throw PendantPageLedgerError.corruptRawPage(identity) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: url, options: .atomic)
    }

    private func replaceAndPersist(_ record: PendantPageRecord) throws {
        let old = recordsByIdentity[record.identity]
        recordsByIdentity[record.identity] = record
        do {
            try persist()
        } catch {
            recordsByIdentity[record.identity] = old
            throw error
        }
    }

    private func persist() throws {
        let document = Document(version: 1, records: recordsByIdentity.values.sorted { $0.receivedAt < $1.receivedAt })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: ledgerURL, options: .atomic)
    }

    private func rawURL(for identity: PendantPageIdentity) -> URL {
        rawPagesURL
            .appendingPathComponent(identity.deviceID, isDirectory: true)
            .appendingPathComponent(identity.sessionID, isDirectory: true)
            .appendingPathComponent(identity.runID, isDirectory: true)
            .appendingPathComponent("\(identity.sequence)-\(identity.pageIndex).raw")
    }

    private static func validate(_ identity: PendantPageIdentity) throws {
        for value in [identity.deviceID, identity.sessionID, identity.runID] {
            guard !value.isEmpty,
                  value != ".", value != "..",
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }) else {
                throw PendantPageLedgerError.unsafeIdentifier(value)
            }
        }
        guard identity.sequence >= 0 else { throw PendantPageLedgerError.invalidSequence }
        guard identity.pageIndex >= 0 else { throw PendantPageLedgerError.invalidPageIndex }
    }
}
