import AVFoundation
import Combine
import Foundation

@MainActor
final class LibraryPlaybackController: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var url: URL?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
    }

    func load(_ url: URL) {
        stop()
        guard !url.hasDirectoryPath else {
            errorMessage = "This recording has no finalized playback asset yet."
            return
        }
        self.url = url
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        isReady = true
        errorMessage = nil
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds
                if let seconds = player?.currentItem?.duration.seconds, seconds.isFinite { self.duration = seconds }
            }
        }
    }

    func toggle() {
        guard let player, isReady else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        guard let player, isReady else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    func stop() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = nil
    }
}
