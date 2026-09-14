import Foundation

/// The audio source selected for a local Mac recording.
enum MacAudioCaptureSource: Codable, Hashable, Sendable {
    case systemAudio
    case application(MacAudioCaptureApplication)
}

/// A ScreenCaptureKit application that may be selected without retaining framework objects.
struct MacAudioCaptureApplication: Codable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: Int32
    let name: String

    var id: String { "\(bundleIdentifier ?? "pid")-\(processIdentifier)" }
}

struct MacAudioCaptureRequest: Codable, Hashable, Sendable {
    var source: MacAudioCaptureSource
    var includeMicrophone: Bool
    var segmentDuration: TimeInterval

    init(source: MacAudioCaptureSource, includeMicrophone: Bool = false, segmentDuration: TimeInterval = 300) {
        self.source = source
        self.includeMicrophone = includeMicrophone
        self.segmentDuration = max(30, segmentDuration)
    }
}

enum MacAudioCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case recording
    case stopped
    case failed
}

struct MacAudioCaptureSegment: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let track: String
    let fileName: String
    let startedAt: Date
    var endedAt: Date?
    var frameCount: Int64
    var isFinalized: Bool
}

/// Persisted beside captured CAF files. An unfinished segment is intentionally retained so a
/// subsequent launch can identify audio left behind by an interrupted process.
struct MacAudioCaptureManifest: Codable, Sendable {
    let recordingID: UUID
    let createdAt: Date
    var updatedAt: Date
    var source: MacAudioCaptureSource
    var includesMicrophone: Bool
    var segments: [MacAudioCaptureSegment]
}
