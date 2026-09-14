import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import AVFoundation

@MainActor
final class MacAudioCaptureService: NSObject, ObservableObject {
    @Published private(set) var state: MacAudioCaptureState = .idle
    @Published private(set) var eligibleApplications: [MacAudioCaptureApplication] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var systemAudioLevel: Float = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var recordingDirectory: URL?

    private var stream: SCStream?
    private var streamOutput: ScreenAudioOutput?
    private var systemWriter: SegmentedAudioWriter?
    private var microphoneWriter: SegmentedAudioWriter?
    private var microphoneEngine: AVAudioEngine?

    func refreshEligibleApplications() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            eligibleApplications = content.applications.compactMap { application in
                guard application.processID != ownPID else { return nil }
                let name = application.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return MacAudioCaptureApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifier: application.processID,
                    name: name
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if state == .idle || state == .failed { state = .ready }
        } catch {
            fail(error)
        }
    }

    /// Prompts only for permissions needed by the supplied request. Screen Recording is required
    /// by ScreenCaptureKit even when the requested output is audio-only.
    func requestPermissions(for request: MacAudioCaptureRequest) async -> Bool {
        state = .requestingPermission
        errorMessage = nil
        var granted = CGPreflightScreenCaptureAccess()
        if !granted { granted = CGRequestScreenCaptureAccess() }
        guard granted else {
            fail(CaptureFailure.screenRecordingDenied)
            return false
        }
        if request.includeMicrophone {
            let microphoneGranted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: microphoneGranted = true
            case .notDetermined:
                microphoneGranted = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
                }
            default: microphoneGranted = false
            }
            guard microphoneGranted else {
                fail(CaptureFailure.microphoneDenied)
                return false
            }
        }
        state = .ready
        return true
    }

    /// Starts a new caller-rooted recording directory and writes `manifest.json` before samples arrive.
    func start(request: MacAudioCaptureRequest, under root: URL) async {
        guard state == .idle || state == .ready || state == .stopped else { return }
        guard await requestPermissions(for: request) else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw CaptureFailure.noDisplay }
            let filter = try makeFilter(for: request.source, content: content, display: display)
            let directory = root.appendingPathComponent("mac-audio-\(UUID().uuidString)", isDirectory: true)
            let store = try CaptureManifestStore(directory: directory, source: request.source, includesMicrophone: request.includeMicrophone)
            let writer = SegmentedAudioWriter(track: "screen", directory: directory, segmentDuration: request.segmentDuration, manifestStore: store, levelHandler: { [weak self] level in Task { @MainActor in self?.systemAudioLevel = level } }, failureHandler: { [weak self] error in Task { @MainActor in self?.fail(error) } })
            let output = ScreenAudioOutput(writer: writer, failureHandler: { [weak self] error in Task { @MainActor in self?.fail(error) } })
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "app.lesslimitless.screen-audio"))
            systemWriter = writer
            streamOutput = output
            stream = newStream
            recordingDirectory = directory
            if request.includeMicrophone { try startMicrophone(in: directory, request: request, store: store) }
            try await newStream.startCapture()
            state = .recording
        } catch {
            await stop()
            fail(error)
        }
    }

    func stop() async {
        let activeStream = stream
        stream = nil
        streamOutput = nil
        if let activeStream { try? await activeStream.stopCapture() }
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        microphoneEngine = nil
        systemWriter?.finish()
        microphoneWriter?.finish()
        systemWriter = nil
        microphoneWriter = nil
        if state == .recording { state = .stopped }
    }

    private func makeFilter(for source: MacAudioCaptureSource, content: SCShareableContent, display: SCDisplay) throws -> SCContentFilter {
        switch source {
        case .systemAudio:
            return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .application(let selected):
            guard let application = content.applications.first(where: {
                $0.processID == selected.processIdentifier && $0.bundleIdentifier == selected.bundleIdentifier
            }) else {
                throw CaptureFailure.applicationNoLongerAvailable(selected.name)
            }
            return SCContentFilter(display: display, including: [application], exceptingWindows: [])
        }
    }

    private func startMicrophone(in directory: URL, request: MacAudioCaptureRequest, store: CaptureManifestStore) throws {
        let writer = SegmentedAudioWriter(track: "microphone", directory: directory, segmentDuration: request.segmentDuration, manifestStore: store, levelHandler: { [weak self] level in Task { @MainActor in self?.microphoneLevel = level } }, failureHandler: { [weak self] error in Task { @MainActor in self?.fail(error) } })
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
            guard let copied = buffer.copy() as? AVAudioPCMBuffer else { return }
            writer.append(copied)
        }
        engine.prepare()
        try engine.start()
        microphoneWriter = writer
        microphoneEngine = engine
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        Task { [weak self] in
            guard let self else { return }
            await self.stop()
            self.errorMessage = message
            self.state = .failed
        }
    }
}

extension MacAudioCaptureService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.fail(error) }
    }
}

private enum CaptureFailure: LocalizedError {
    case screenRecordingDenied, microphoneDenied, noDisplay, applicationNoLongerAvailable(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied: return "Screen Recording permission is required for Mac audio capture."
        case .microphoneDenied: return "Microphone permission is required when microphone capture is enabled."
        case .noDisplay: return "No shareable display is available for system audio capture."
        case .applicationNoLongerAvailable(let name): return "\(name) is no longer available to capture."
        }
    }
}

private final class ScreenAudioOutput: NSObject, SCStreamOutput {
    private let writer: SegmentedAudioWriter
    private let failureHandler: (Error) -> Void

    init(writer: SegmentedAudioWriter, failureHandler: @escaping (Error) -> Void) {
        self.writer = writer
        self.failureHandler = failureHandler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        writer.append(sampleBuffer: sampleBuffer, onError: failureHandler)
    }
}

/// Serializes AVAudioFile operations and synchronously journals each segment transition.
private final class SegmentedAudioWriter {
    private let track: String
    private let directory: URL
    private let segmentDuration: TimeInterval
    private let store: CaptureManifestStore
    private let queue = DispatchQueue(label: "app.lesslimitless.segment-writer")
    private let levelHandler: (Float) -> Void
    private let failureHandler: (Error) -> Void
    private var file: AVAudioFile?
    private var segment: MacAudioCaptureSegment?

    init(track: String, directory: URL, segmentDuration: TimeInterval, manifestStore: CaptureManifestStore, levelHandler: @escaping (Float) -> Void, failureHandler: @escaping (Error) -> Void) {
        self.track = track; self.directory = directory; self.segmentDuration = segmentDuration
        self.store = manifestStore; self.levelHandler = levelHandler; self.failureHandler = failureHandler
    }

    func append(sampleBuffer: CMSampleBuffer, onError: @escaping (Error) -> Void) {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        append(buffer, explicitErrorHandler: onError)
    }

    func append(_ buffer: AVAudioPCMBuffer) { append(buffer, explicitErrorHandler: failureHandler) }

    private func append(_ buffer: AVAudioPCMBuffer, explicitErrorHandler: @escaping (Error) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.openSegmentIfNeeded(format: buffer.format)
                if let segment = self.segment, Date().timeIntervalSince(segment.startedAt) >= self.segmentDuration {
                    try self.closeSegment()
                    try self.openSegmentIfNeeded(format: buffer.format)
                }
                try self.file?.write(from: buffer)
                self.segment?.frameCount += Int64(buffer.frameLength)
                if let segment = self.segment { try self.store.update(segment) }
                self.levelHandler(Self.level(of: buffer))
            } catch { explicitErrorHandler(error) }
        }
    }

    func finish() {
        queue.sync {
            do { try closeSegment() } catch { failureHandler(error) }
        }
    }

    private func openSegmentIfNeeded(format: AVAudioFormat) throws {
        guard file == nil else { return }
        let id = UUID()
        let name = "\(track)-\(id.uuidString).caf"
        let newSegment = MacAudioCaptureSegment(id: id, track: track, fileName: name, startedAt: Date(), endedAt: nil, frameCount: 0, isFinalized: false)
        file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        segment = newSegment
        try store.add(newSegment)
    }

    private func closeSegment() throws {
        guard var closed = segment else { return }
        file = nil
        closed.endedAt = Date()
        closed.isFinalized = true
        segment = nil
        try store.update(closed)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
        return min(1, sqrt(meanSquare))
    }
}

private final class CaptureManifestStore {
    private let url: URL
    private let lock = NSLock()
    private var manifest: MacAudioCaptureManifest

    init(directory: URL, source: MacAudioCaptureSource, includesMicrophone: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("manifest.json")
        manifest = MacAudioCaptureManifest(recordingID: UUID(), createdAt: Date(), updatedAt: Date(), source: source, includesMicrophone: includesMicrophone, segments: [])
        try persist()
    }

    func add(_ segment: MacAudioCaptureSegment) throws {
        lock.lock(); defer { lock.unlock() }
        manifest.segments.append(segment); manifest.updatedAt = Date(); try persist()
    }

    func update(_ segment: MacAudioCaptureSegment) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = manifest.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        manifest.segments[index] = segment; manifest.updatedAt = Date(); try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = url.appendingPathExtension("tmp")
        try encoder.encode(manifest).write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
