import Foundation

public struct PendantPageIngestion: Sendable {
    public let result: PendantPageIngestResult
    public let storageBuffer: PendantStorageBuffer
    public let summary: FlashPageSummary?
}

public enum PendantPageIngestorError: Error, Equatable, Sendable {
    case missingIdentityField(String)
    case valueOutOfRange(String)
    case deviceReportedPageError(UInt64)
}

/// Serializes raw storage-page ingestion. It preserves raw `FlashPage` bytes
/// first, then parses a bounded summary; parsing failure never removes a vault
/// copy and is reported as a failed verification state.
public actor PendantPageIngestor {
    private let ledger: PendantPageLedger
    private let parser: FlashPageParser

    public init(rootURL: URL, parser: FlashPageParser? = nil) throws {
        self.ledger = try PendantPageLedger(rootURL: rootURL)
        self.parser = try parser ?? FlashPageParser()
    }

    public func ingest(_ pendantAllMessage: Data, deviceID: String, receivedAt: Date = Date()) throws -> PendantPageIngestion? {
        guard let buffer = try PendantStorageBufferParser.decode(from: pendantAllMessage) else { return nil }
        let identity = try makeIdentity(buffer, deviceID: deviceID)
        guard let flashPage = buffer.flashPage else {
            throw PendantPageIngestorError.deviceReportedPageError(buffer.pageError ?? 0)
        }
        let result = try ledger.ingest(flashPage, for: identity, receivedAt: receivedAt)
        if let pageError = buffer.pageError, pageError != 0 {
            try? ledger.markFailed(identity, reason: "Pendant reported flash page error \(pageError)")
            return PendantPageIngestion(result: result, storageBuffer: buffer, summary: nil)
        }
        do {
            let summary = try parser.decode(flashPage)
            return PendantPageIngestion(result: result, storageBuffer: buffer, summary: summary)
        } catch {
            // The immutable raw page remains available for a future decoder.
            try? ledger.markFailed(identity, reason: "Flash page parser rejected data")
            return PendantPageIngestion(result: result, storageBuffer: buffer, summary: nil)
        }
    }

    public func recordCount() -> Int { ledger.records.count }
    public func records() -> [PendantPageRecord] { ledger.records }

    private func makeIdentity(_ buffer: PendantStorageBuffer, deviceID: String) throws -> PendantPageIdentity {
        let session = try requiredInt(buffer.session, name: "session")
        let run = try requiredInt(buffer.run, name: "run")
        let sequence = try requiredInt(buffer.sequence, name: "sequence")
        let pageIndex = try requiredInt(buffer.pageIndex, name: "page index")
        return PendantPageIdentity(
            deviceID: deviceID,
            sessionID: String(session),
            runID: String(run),
            sequence: sequence,
            pageIndex: pageIndex
        )
    }

    private func requiredInt(_ value: UInt64?, name: String) throws -> Int {
        guard let value else { throw PendantPageIngestorError.missingIdentityField(name) }
        guard value <= UInt64(Int.max) else { throw PendantPageIngestorError.valueOutOfRange(name) }
        return Int(value)
    }
}
