import Crypto
import Foundation

public struct RawOpusArchiveManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let opusSHA256: String
    public let byteCount: Int

    public init(version: Int = 1, sessionID: String, opusSHA256: String, byteCount: Int) {
        self.version = version
        self.sessionID = sessionID
        self.opusSHA256 = opusSHA256
        self.byteCount = byteCount
    }
}

public struct RawOpusArchive: Equatable, Sendable {
    public let opusURL: URL
    public let manifestURL: URL
    public let manifest: RawOpusArchiveManifest

    public init(opusURL: URL, manifestURL: URL, manifest: RawOpusArchiveManifest) {
        self.opusURL = opusURL
        self.manifestURL = manifestURL
        self.manifest = manifest
    }
}

public enum RawOpusArchiveError: Error, Equatable, Sendable {
    case unsafeSessionID(String)
    case unsafeArchivePath
    case collision(sessionID: String, existingHash: String, incomingHash: String)
    case corruptArchive(sessionID: String)
}

/// Commits each raw stream and its manifest as one immutable session directory.
/// There is deliberately no replace/delete API: a concurrent conflicting writer
/// either observes the first completed archive or receives a collision error.
public final class RawOpusArchiveWriter {
    private let rootURL: URL
    private let lock = NSLock()

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try validateDirectory(self.rootURL)
    }

    public convenience init(root: URL) throws { try self.init(rootURL: root) }

    @discardableResult
    public func write(opusData: Data, sessionID: String) throws -> RawOpusArchive {
        try validate(sessionID: sessionID)
        lock.lock(); defer { lock.unlock() }
        try validateDirectory(rootURL)
        let finalURL = rootURL.appendingPathComponent("\(sessionID).archive", isDirectory: true)
        let incomingHash = Self.sha256Hex(opusData)
        let manifest = RawOpusArchiveManifest(sessionID: sessionID, opusSHA256: incomingHash, byteCount: opusData.count)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            return try validateExisting(finalURL, sessionID: sessionID, incomingHash: incomingHash, expectedManifest: manifest)
        }

        let temporaryURL = rootURL.appendingPathComponent(".\(sessionID).\(UUID().uuidString).staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        let opusURL = temporaryURL.appendingPathComponent("stream.opus.raw")
        let manifestURL = temporaryURL.appendingPathComponent("manifest.json")
        try opusData.write(to: opusURL, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            guard FileManager.default.fileExists(atPath: finalURL.path) else { throw error }
            return try validateExisting(finalURL, sessionID: sessionID, incomingHash: incomingHash, expectedManifest: manifest)
        }
        return RawOpusArchive(
            opusURL: finalURL.appendingPathComponent("stream.opus.raw"),
            manifestURL: finalURL.appendingPathComponent("manifest.json"),
            manifest: manifest
        )
    }

    @discardableResult
    public func write(_ opusData: Data, forSession sessionID: String) throws -> RawOpusArchive {
        try write(opusData: opusData, sessionID: sessionID)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateExisting(_ directory: URL, sessionID: String, incomingHash: String, expectedManifest: RawOpusArchiveManifest) throws -> RawOpusArchive {
        try validateDirectory(directory)
        let opusURL = directory.appendingPathComponent("stream.opus.raw")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try rejectSymbolicLink(at: opusURL)
        try rejectSymbolicLink(at: manifestURL)
        let existing = try Data(contentsOf: opusURL)
        let existingHash = Self.sha256Hex(existing)
        guard existingHash == incomingHash else {
            throw RawOpusArchiveError.collision(sessionID: sessionID, existingHash: existingHash, incomingHash: incomingHash)
        }
        let persisted = try JSONDecoder().decode(RawOpusArchiveManifest.self, from: Data(contentsOf: manifestURL))
        guard persisted == expectedManifest else { throw RawOpusArchiveError.corruptArchive(sessionID: sessionID) }
        return RawOpusArchive(opusURL: opusURL, manifestURL: manifestURL, manifest: persisted)
    }

    private func validate(sessionID: String) throws {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..",
              sessionID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            throw RawOpusArchiveError.unsafeSessionID(sessionID)
        }
    }

    private func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RawOpusArchiveError.unsafeArchivePath }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw RawOpusArchiveError.unsafeArchivePath }
    }
}
