import AVFoundation
import Foundation

/// Produces one playable local M4A from finalized ScreenCaptureKit CAF segments.
/// Original per-track segments and the recovery manifest are retained unchanged.
enum CaptureFinalizer {
    enum Error: LocalizedError {
        case noFinalizedScreenSegments
        case noAudioTrack(URL)
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .noFinalizedScreenSegments: "No finalized screen-audio segments were available."
            case .noAudioTrack(let url): "No audio track was found in \(url.lastPathComponent)."
            case .exportFailed: "Could not export the captured audio."
            }
        }
    }

    static func finalize(directory: URL) async throws -> URL {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(MacAudioCaptureManifest.self, from: Data(contentsOf: manifestURL))
        let segments = manifest.segments
            .filter { $0.track == "screen" && $0.isFinalized }
            .sorted { $0.startedAt < $1.startedAt }
        guard !segments.isEmpty else { throw Error.noFinalizedScreenSegments }

        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Error.exportFailed
        }
        var cursor = CMTime.zero
        for segment in segments {
            let url = directory.appendingPathComponent(segment.fileName)
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw Error.noAudioTrack(url) }
            let duration = try await asset.load(.duration)
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }

        let output = directory.appendingPathComponent("recording.m4a")
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw Error.exportFailed
        }
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else { throw Error.exportFailed }
        return output
    }
}
