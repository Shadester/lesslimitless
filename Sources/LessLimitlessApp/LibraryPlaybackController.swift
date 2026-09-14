import AVFoundation
import Combine
import Foundation

@MainActor
final class LibraryPlaybackController: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var url: URL?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ url: URL) {
        stop()
        guard !url.hasDirectoryPath else {
            errorMessage = "This recording has no finalized playback asset yet."
            return
        }
        self.url = url
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
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

    func stop() {
        player?.pause()
        player = nil
        isPlaying = false
        isReady = false
    }
}
