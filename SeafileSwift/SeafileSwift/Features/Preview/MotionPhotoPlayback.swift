import AVFoundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class MotionPhotoPlaybackController {
    private(set) var isPlaying = false
    private(set) var hasVideo = false
    private(set) var videoURL: URL?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    var currentPlayer: AVPlayer? { player }

    func configure(videoURL: URL?) {
        release()
        self.videoURL = videoURL
        hasVideo = videoURL != nil
    }

    func play(muted: Bool) {
        guard let videoURL else { return }
        let player: AVPlayer
        if let existing = self.player {
            player = existing
        } else {
            player = AVPlayer(url: videoURL)
            player.actionAtItemEnd = .pause
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                object: player.currentItem,
                                                                queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            self.player = player
        }
        player.isMuted = muted
        player.seek(to: .zero)
        player.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
    }

    func release() {
        stop()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player = nil
        if let videoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }
        videoURL = nil
        hasVideo = false
    }
}

struct MotionPhotoVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MotionPhotoPlayerUIView {
        let view = MotionPhotoPlayerUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: MotionPhotoPlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class MotionPhotoPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct LivePhotoBadge: View {
    var body: some View {
        Label("LIVE", systemImage: "livephoto")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .accessibilityLabel("Live Photo")
    }
}
