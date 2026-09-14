import Foundation

/// One parsed page and its immutable pendant identity, supplied to the assembler.
public struct PendantSessionPage: Equatable, Sendable {
    public let identity: PendantPageIdentity
    public let summary: FlashPageSummary

    public init(identity: PendantPageIdentity, summary: FlashPageSummary) {
        self.identity = identity
        self.summary = summary
    }
}

/// A page's usable encoded audio contribution. `encodedOpusBytes` are copied
/// directly from parsed codec fields; they are never decoded or transformed.
public struct PendantSessionPageContribution: Equatable, Sendable {
    public let identity: PendantPageIdentity
    public let timestamp: UInt64?
    public let encodedOpusBytes: [Data]

    public init(identity: PendantPageIdentity, timestamp: UInt64?, encodedOpusBytes: [Data]) {
        self.identity = identity
        self.timestamp = timestamp
        self.encodedOpusBytes = encodedOpusBytes
    }
}

public enum PendantSessionBoundary: Equatable, Sendable {
    case recordingStarted(PendantPageIdentity)
    case recordingStopped(PendantPageIdentity)
    case timestampGap(previous: PendantPageIdentity, next: PendantPageIdentity)
}

public enum PendantSessionDiagnostic: Equatable, Sendable {
    case missingTimestamp(PendantPageIdentity)
    case encryptedAudioUnavailable(PendantPageIdentity)
    case unsupportedCodec(PendantPageIdentity, codecType: UInt64)
    case invalidOpusFrameCount(PendantPageIdentity, numFrames: UInt64?)
}

public struct PendantSessionManifest: Equatable, Sendable {
    public let index: Int
    public let contributions: [PendantSessionPageContribution]
    public let openingBoundary: PendantSessionBoundary?
    public let closingBoundary: PendantSessionBoundary?

    public init(index: Int, contributions: [PendantSessionPageContribution], openingBoundary: PendantSessionBoundary?, closingBoundary: PendantSessionBoundary?) {
        self.index = index
        self.contributions = contributions
        self.openingBoundary = openingBoundary
        self.closingBoundary = closingBoundary
    }
}

public struct PendantSessionAssembly: Equatable, Sendable {
    public let sessions: [PendantSessionManifest]
    public let diagnostics: [PendantSessionDiagnostic]

    public init(sessions: [PendantSessionManifest], diagnostics: [PendantSessionDiagnostic]) {
        self.sessions = sessions
        self.diagnostics = diagnostics
    }
}

/// Pure assembly of parsed page summaries. It does not access storage, decode
/// audio, communicate with a pendant, or alter raw page data.
public struct PendantSessionAssembler: Sendable {
    public static let timestampGapMilliseconds: UInt64 = 5 * 60 * 1_000

    public init() {}

    public func assemble(_ pages: [PendantSessionPage]) -> PendantSessionAssembly {
        let grouped = Dictionary(grouping: pages, by: GroupKey.init)
        var sessions: [PendantSessionManifest] = []
        var diagnostics: [PendantSessionDiagnostic] = []

        for key in grouped.keys.sorted() {
            let result = assembleGroup(grouped[key] ?? [])
            diagnostics.append(contentsOf: result.diagnostics)
            for session in result.sessions {
                sessions.append(PendantSessionManifest(
                    index: sessions.count,
                    contributions: session.contributions,
                    openingBoundary: session.openingBoundary,
                    closingBoundary: session.closingBoundary
                ))
            }
        }
        return PendantSessionAssembly(sessions: sessions, diagnostics: diagnostics)
    }
    private func assembleGroup(_ pages: [PendantSessionPage]) -> PendantSessionAssembly {
        let useTimestamps = pages.allSatisfy { $0.summary.timestamp != nil }
        let ordered = pages.sorted { isOrderedBefore($0, $1, useTimestamps: useTimestamps) }
        var sessions: [PendantSessionManifest] = []
        var diagnostics: [PendantSessionDiagnostic] = []
        var contributions: [PendantSessionPageContribution] = []
        var openingBoundary: PendantSessionBoundary?
        var previous: PendantSessionPage?

        func finish(_ closingBoundary: PendantSessionBoundary?) {
            guard !contributions.isEmpty else { return }
            sessions.append(PendantSessionManifest(
                index: sessions.count,
                contributions: contributions,
                openingBoundary: openingBoundary,
                closingBoundary: closingBoundary
            ))
            contributions = []
            openingBoundary = nil
        }

        for page in ordered {
            let audio = page.summary.chunks.compactMap(\.audioData)
            let hasStart = audio.contains { $0.didStartRecording == true }
            let hasStop = audio.contains { $0.didStopRecording == true }
            if page.summary.timestamp == nil { diagnostics.append(.missingTimestamp(page.identity)) }

            var boundary: PendantSessionBoundary?
            if hasStart {
                boundary = .recordingStarted(page.identity)
            } else if let previous, let previousTimestamp = previous.summary.timestamp,
                      let timestamp = page.summary.timestamp,
                      timestamp >= previousTimestamp,
                      timestamp - previousTimestamp >= Self.timestampGapMilliseconds {
                boundary = .timestampGap(previous: previous.identity, next: page.identity)
            }
            if let boundary {
                finish(boundary)
                openingBoundary = boundary
            }

            var opus: [Data] = []
            for item in audio {
                if item.hasEncryptedCodecPayload {
                    diagnostics.append(.encryptedAudioUnavailable(page.identity))
                } else if let codecType = item.codecType, codecType != 1 {
                    diagnostics.append(.unsupportedCodec(page.identity, codecType: codecType))
                } else if let bytes = item.preferredEncodedAudio {
                    guard item.numFrames == 1 else {
                        diagnostics.append(.invalidOpusFrameCount(page.identity, numFrames: item.numFrames))
                        continue
                    }
                    opus.append(bytes)
                }
            }
            contributions.append(PendantSessionPageContribution(identity: page.identity, timestamp: page.summary.timestamp, encodedOpusBytes: opus))
            if hasStop { finish(.recordingStopped(page.identity)) }
            previous = page
        }
        finish(nil)
        return PendantSessionAssembly(sessions: sessions, diagnostics: diagnostics)
    }

    /// Uses timestamp order only when a whole recording group has timestamps;
    /// otherwise sequence/index provides a total stable ordering.
    private func isOrderedBefore(_ lhs: PendantSessionPage, _ rhs: PendantSessionPage, useTimestamps: Bool) -> Bool {
        if useTimestamps, lhs.summary.timestamp != rhs.summary.timestamp {
            return lhs.summary.timestamp! < rhs.summary.timestamp!
        }
        if lhs.identity.sequence != rhs.identity.sequence { return lhs.identity.sequence < rhs.identity.sequence }
        return lhs.identity.pageIndex < rhs.identity.pageIndex
    }

    private struct GroupKey: Hashable, Comparable {
        let deviceID: String
        let sessionID: String
        let runID: String

        init(_ page: PendantSessionPage) {
            deviceID = page.identity.deviceID
            sessionID = page.identity.sessionID
            runID = page.identity.runID
        }

        static func < (lhs: GroupKey, rhs: GroupKey) -> Bool {
            if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
            if lhs.sessionID != rhs.sessionID { return lhs.sessionID < rhs.sessionID }
            return lhs.runID < rhs.runID
        }
    }
}
