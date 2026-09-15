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
    /// Default gap that closes one encounter and opens the next. The firmware mints
    /// a new sessionID per voice-activity burst, so within a real wearing session
    /// bursts sit a few seconds apart; 2 minutes comfortably separates that from a
    /// genuine pause between encounters. Fitted against on-device data (largest
    /// intra-encounter gap observed: 3.9 min), so it is a tuning knob, not a fact.
    public static let defaultEncounterGapMilliseconds: UInt64 = 2 * 60 * 1_000

    private let encounterGapMilliseconds: UInt64

    public init(encounterGapMilliseconds: UInt64 = Self.defaultEncounterGapMilliseconds) {
        self.encounterGapMilliseconds = encounterGapMilliseconds
    }

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

    /// A group is one device's pages, spanning many firmware bursts. Only a
    /// timestamp gap splits it into encounters; `didStartRecording`/`didStopRecording`
    /// fire once per burst on real firmware and are recorded as provenance on the
    /// opening/closing page of an encounter, never as a split trigger.
    private func assembleGroup(_ pages: [PendantSessionPage]) -> PendantSessionAssembly {
        let ordered = pages.sorted(by: isOrderedBefore)
        var sessions: [PendantSessionManifest] = []
        var diagnostics: [PendantSessionDiagnostic] = []
        var contributions: [PendantSessionPageContribution] = []
        var openingBoundary: PendantSessionBoundary?
        var pendingClosing: PendantSessionBoundary?
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
            pendingClosing = nil
        }

        for page in ordered {
            let audio = page.summary.chunks.compactMap(\.audioData)
            let hasStart = audio.contains { $0.didStartRecording == true }
            let hasStop = audio.contains { $0.didStopRecording == true }
            if page.summary.timestamp == nil { diagnostics.append(.missingTimestamp(page.identity)) }

            if let previous, let previousTimestamp = previous.summary.timestamp,
               let timestamp = page.summary.timestamp,
               timestamp >= previousTimestamp,
               timestamp - previousTimestamp >= encounterGapMilliseconds {
                let boundary = PendantSessionBoundary.timestampGap(previous: previous.identity, next: page.identity)
                finish(pendingClosing ?? boundary)
                openingBoundary = boundary
            }
            if contributions.isEmpty, openingBoundary == nil, hasStart {
                openingBoundary = .recordingStarted(page.identity)
            }

            var opus: [Data] = []
            for item in audio {
                if item.hasEncryptedCodecPayload {
                    diagnostics.append(.encryptedAudioUnavailable(page.identity))
                } else if let codecType = item.codecType, codecType != 1 {
                    diagnostics.append(.unsupportedCodec(page.identity, codecType: codecType))
                } else if let bytes = item.preferredEncodedAudio {
                    // Real firmware leaves numFrames/codecType unset on ordinary audio
                    // chunks; only treat an explicit non-1 value as invalid.
                    guard item.numFrames == nil || item.numFrames == 1 else {
                        diagnostics.append(.invalidOpusFrameCount(page.identity, numFrames: item.numFrames))
                        continue
                    }
                    opus.append(bytes)
                }
            }
            contributions.append(PendantSessionPageContribution(identity: page.identity, timestamp: page.summary.timestamp, encodedOpusBytes: opus))
            pendingClosing = hasStop ? .recordingStopped(page.identity) : pendingClosing
            previous = page
        }
        finish(pendingClosing)
        return PendantSessionAssembly(sessions: sessions, diagnostics: diagnostics)
    }

    /// Total order across a whole encounter, which may span many bursts (and thus
    /// many sessionIDs/sequence counters). Timestamp wins when both pages have one;
    /// otherwise falls back to sessionID (numeric, since it restarts per burst),
    /// then sequence, then pageIndex.
    private func isOrderedBefore(_ lhs: PendantSessionPage, _ rhs: PendantSessionPage) -> Bool {
        if let l = lhs.summary.timestamp, let r = rhs.summary.timestamp, l != r {
            return l < r
        }
        let lSessionID = lhs.identity.sessionID, rSessionID = rhs.identity.sessionID
        if let l = Int(lSessionID), let r = Int(rSessionID), l != r { return l < r }
        if lSessionID != rSessionID { return lSessionID < rSessionID }
        if lhs.identity.sequence != rhs.identity.sequence { return lhs.identity.sequence < rhs.identity.sequence }
        return lhs.identity.pageIndex < rhs.identity.pageIndex
    }

    private struct GroupKey: Hashable, Comparable {
        let deviceID: String

        init(_ page: PendantSessionPage) {
            deviceID = page.identity.deviceID
        }

        static func < (lhs: GroupKey, rhs: GroupKey) -> Bool { lhs.deviceID < rhs.deviceID }
    }
}
