import Foundation

/// Metadata committed with a decoded WAV session. The source hash preserves the
/// supplied packet boundaries; it is not a hash of an inferred raw byte stream.
public struct DecodedSessionExportManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let opusSHA256: String
    public let wavSHA256: String
    public let wavByteCount: Int

    public init(version: Int = 1, sessionID: String, opusSHA256: String, wavSHA256: String, wavByteCount: Int) {
        self.version = version
        self.sessionID = sessionID
        self.opusSHA256 = opusSHA256
        self.wavSHA256 = wavSHA256
        self.wavByteCount = wavByteCount
    }
}

public struct DecodedSessionExport: Equatable, Sendable {
    public let wavURL: URL
    public let manifestURL: URL
    public let manifest: DecodedSessionExportManifest

    public init(wavURL: URL, manifestURL: URL, manifest: DecodedSessionExportManifest) {
        self.wavURL = wavURL
        self.manifestURL = manifestURL
        self.manifest = manifest
    }
}

public enum DecodedSessionExporterError: Error, Equatable, Sendable {
    case noPackets
    case unsafeSessionID(String)
    case unsafeExportPath
    case decodeFailed
    case collision(sessionID: String, existingHash: String, incomingHash: String)
    case corruptExport(sessionID: String)
}

/// Atomically exports packet-aligned Opus contributions as immutable local WAV.
/// It never attempts to recover packet boundaries from concatenated raw bytes.
public final class DecodedSessionExporter {
    private let rootURL: URL
    private let lock = NSLock()

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try validateDirectory(self.rootURL)
    }

    public convenience init(root: URL) throws { try self.init(rootURL: root) }

    @discardableResult
    public func export(_ session: PendantSessionManifest, sessionID: String) throws -> DecodedSessionExport {
        try validate(sessionID: sessionID)
        let packets = session.contributions.flatMap(\.encodedOpusBytes)
        guard !packets.isEmpty else { throw DecodedSessionExporterError.noPackets }
        guard packets.allSatisfy({ $0.count <= OpusDecoder.maximumPacketBytes }),
              packets.reduce(0, { $0 <= OpusDecoder.defaultMaximumInputBytes - $1.count ? $0 + $1.count : Int.max }) <= OpusDecoder.defaultMaximumInputBytes else {
            throw DecodedSessionExporterError.decodeFailed
        }
        let incomingHash = RawOpusArchiveWriter.sha256Hex(packetAlignedData(packets))

        lock.lock(); defer { lock.unlock() }
        try validateDirectory(rootURL)
        let finalURL = rootURL.appendingPathComponent("\(sessionID).wav.export", isDirectory: true)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return try validateExisting(finalURL, sessionID: sessionID, incomingHash: incomingHash)
        }

        let pcm: [Float]
        do {
            pcm = try OpusDecoder.decode(packets: packets)
        } catch {
            throw DecodedSessionExporterError.decodeFailed
        }
        let wav: Data
        do {
            wav = try WAVWriter.pcm16Data(samples: pcm, sampleRate: OpusDecoder.sampleRate, channels: OpusDecoder.channels)
        } catch {
            throw DecodedSessionExporterError.decodeFailed
        }
        let manifest = DecodedSessionExportManifest(
            sessionID: sessionID,
            opusSHA256: incomingHash,
            wavSHA256: RawOpusArchiveWriter.sha256Hex(wav),
            wavByteCount: wav.count
        )

        let temporaryURL = rootURL.appendingPathComponent(".\(sessionID).\(UUID().uuidString).staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        try wav.write(to: temporaryURL.appendingPathComponent("audio.wav"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: temporaryURL.appendingPathComponent("manifest.json"), options: .atomic)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            guard FileManager.default.fileExists(atPath: finalURL.path) else { throw error }
            return try validateExisting(finalURL, sessionID: sessionID, incomingHash: incomingHash)
        }
        return DecodedSessionExport(
            wavURL: finalURL.appendingPathComponent("audio.wav"),
            manifestURL: finalURL.appendingPathComponent("manifest.json"),
            manifest: manifest
        )
    }

    @discardableResult
    public func write(session: PendantSessionManifest, sessionID: String) throws -> DecodedSessionExport {
        try export(session, sessionID: sessionID)
    }

    private func validateExisting(_ directory: URL, sessionID: String, incomingHash: String) throws -> DecodedSessionExport {
        try validateDirectory(directory)
        let wavURL = directory.appendingPathComponent("audio.wav")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try rejectSymbolicLink(at: wavURL)
        try rejectSymbolicLink(at: manifestURL)
        let manifest = try JSONDecoder().decode(DecodedSessionExportManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.sessionID == sessionID else { throw DecodedSessionExporterError.corruptExport(sessionID: sessionID) }
        guard manifest.opusSHA256 == incomingHash else {
            throw DecodedSessionExporterError.collision(sessionID: sessionID, existingHash: manifest.opusSHA256, incomingHash: incomingHash)
        }
        let wav = try Data(contentsOf: wavURL)
        guard manifest.wavByteCount == wav.count,
              manifest.wavSHA256 == RawOpusArchiveWriter.sha256Hex(wav) else {
            throw DecodedSessionExporterError.corruptExport(sessionID: sessionID)
        }
        return DecodedSessionExport(wavURL: wavURL, manifestURL: manifestURL, manifest: manifest)
    }

    private func packetAlignedData(_ packets: [Data]) -> Data {
        var data = Data()
        for packet in packets {
            var length = UInt32(packet.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(packet)
        }
        return data
    }

    private func validate(sessionID: String) throws {
        guard !sessionID.isEmpty, sessionID != ".", sessionID != "..",
              sessionID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            throw DecodedSessionExporterError.unsafeSessionID(sessionID)
        }
    }

    private func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DecodedSessionExporterError.unsafeExportPath }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw DecodedSessionExporterError.unsafeExportPath }
    }
}
