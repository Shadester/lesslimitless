import Foundation
import Domain

public enum LocalLibraryStoreError: Error, Equatable, Sendable {
    case duplicateRecording(UUID)
    case invalidMediaRelativePath(String)
    case recordingNotFound(UUID)
    case corruptStore
}

/// A caller-rooted, actor-isolated JSON library. Media is never created or
/// moved by this store; it may only be removed when its validated relative path
/// still resolves beneath the supplied root.
public actor LocalLibraryStore {
    private struct PersistedLibrary: Codable {
        var version: Int
        var recordings: [LibraryRecording]
    }

    private let rootURL: URL
    private let storeURL: URL
    private var records: [UUID: LibraryRecording]

    public init(rootURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.storeURL = self.rootURL.appendingPathComponent("library.json", isDirectory: false)

        guard fileManager.fileExists(atPath: storeURL.path) else {
            self.records = [:]
            return
        }
        do {
            let decoded = try JSONDecoder.libraryDecoder.decode(PersistedLibrary.self, from: Data(contentsOf: storeURL))
            guard decoded.version == 1 else { throw LocalLibraryStoreError.corruptStore }
            var loaded: [UUID: LibraryRecording] = [:]
            for recording in decoded.recordings {
                if let path = recording.mediaRelativePath {
                    try Self.validateRelativePath(path)
                }
                guard loaded[recording.id] == nil else { throw LocalLibraryStoreError.corruptStore }
                loaded[recording.id] = recording
            }
            self.records = loaded
        } catch let error as LocalLibraryStoreError {
            throw error
        } catch {
            throw LocalLibraryStoreError.corruptStore
        }
    }

    public func recordings() -> [LibraryRecording] {
        records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func allRecordings() -> [LibraryRecording] { recordings() }

    public func recording(id: UUID) -> LibraryRecording? { records[id] }

    public func create(_ recording: LibraryRecording) throws {
        guard records[recording.id] == nil else { throw LocalLibraryStoreError.duplicateRecording(recording.id) }
        try upsert(recording)
    }

    public func upsert(_ recording: LibraryRecording) throws {
        if let path = recording.mediaRelativePath { try Self.validateRelativePath(path) }
        let old = records[recording.id]
        records[recording.id] = recording
        do {
            try persist()
        } catch {
            if let old { records[recording.id] = old } else { records.removeValue(forKey: recording.id) }
            throw error
        }
    }

    public func delete(id: UUID) throws {
        guard let recording = records[id] else { throw LocalLibraryStoreError.recordingNotFound(id) }
        var trashedURL: URL?
        var originalURL: URL?
        if let path = recording.mediaRelativePath {
            let mediaURL = try ownedMediaURL(for: path)
            if FileManager.default.fileExists(atPath: mediaURL.path) {
                let trash = rootURL.appendingPathComponent(".trash", isDirectory: true)
                    .appendingPathComponent("\(recording.id.uuidString)-\(mediaURL.lastPathComponent)")
                try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: mediaURL, to: trash)
                trashedURL = trash
                originalURL = mediaURL
            }
        }
        records.removeValue(forKey: id)
        do {
            try persist()
        } catch {
            records[id] = recording
            if let trashedURL, let originalURL, FileManager.default.fileExists(atPath: trashedURL.path) {
                try? FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: trashedURL, to: originalURL)
            }
            throw error
        }
        if let trashedURL { try? FileManager.default.removeItem(at: trashedURL) }
    }

    public func delete(_ id: UUID) throws { try delete(id: id) }

    /// Returns the safe on-disk location for a recording's media, if it has one.
    public func mediaURL(for recording: LibraryRecording) throws -> URL? {
        guard let path = recording.mediaRelativePath else { return nil }
        return try ownedMediaURL(for: path)
    }

    public func search(_ query: String) -> [LibrarySearchResult] {
        let queryTokens = Self.tokens(query)
        guard !queryTokens.isEmpty else { return [] }

        return records.values.compactMap { recording in
            let fields: [(LibrarySearchField, Int, [String])] = [
                (.title, 12, Self.tokens(recording.title)),
                (.notes, 6, Self.tokens(recording.notes)),
                (.tags, 9, recording.tags.flatMap(Self.tokens)),
                (.transcript, 4, recording.transcriptSegments.flatMap { Self.tokens($0.text) }),
                (.generatedArtifact, 3, recording.generatedArtifacts.flatMap { Self.tokens($0.kind) + Self.tokens($0.text) })
            ]
            var matchedFields = Set<LibrarySearchField>()
            var score = 0
            var foundTokens = Set<String>()
            for (field, weight, words) in fields {
                let matchedCount = queryTokens.reduce(into: 0) { count, token in
                    if words.contains(token) {
                        count += 1
                        foundTokens.insert(token)
                    }
                }
                if matchedCount > 0 {
                    matchedFields.insert(field)
                    score += matchedCount * weight
                }
            }
            guard foundTokens.count == queryTokens.count else { return nil }
            return LibrarySearchResult(recording: recording, score: score, matchedFields: matchedFields)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.recording.updatedAt != $1.recording.updatedAt { return $0.recording.updatedAt > $1.recording.updatedAt }
            return $0.recording.id.uuidString < $1.recording.id.uuidString
        }
    }

    private func persist() throws {
        let library = PersistedLibrary(version: 1, recordings: records.values.sorted { $0.id.uuidString < $1.id.uuidString })
        let data = try JSONEncoder.libraryEncoder.encode(library)
        try data.write(to: storeURL, options: .atomic)
    }

    private func ownedMediaURL(for relativePath: String) throws -> URL {
        try Self.validateRelativePath(relativePath)
        let candidate = rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard Self.isDescendant(resolved, of: rootURL) else {
            throw LocalLibraryStoreError.invalidMediaRelativePath(relativePath)
        }
        return candidate
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw LocalLibraryStoreError.invalidMediaRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalLibraryStoreError.invalidMediaRelativePath(path)
        }
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        return candidate.count > base.count && candidate.starts(with: base)
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                result.append(String(current))
                current.removeAll()
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }
}

private extension JSONEncoder {
    static var libraryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var libraryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
