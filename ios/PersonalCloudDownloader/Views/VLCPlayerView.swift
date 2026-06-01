import SwiftUI
import MobileVLCKit

/// Owns the `VLCMediaPlayer` for one playback screen and publishes its
/// play/pause state so SwiftUI controls can reflect it.
///
/// Shared between `VLCPlayerView` (sets drawable + media) and `PlayerView`
/// (renders the play/pause button + interactive seek slider). Step 6C scope
/// adds a scrub slider and ±10s skip — no full custom player UI.
final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    /// Seconds the skip-back / skip-forward buttons jump.
    static let skipInterval: Int32 = 10

    /// High-level playback lifecycle, derived from `VLCMediaPlayerState`.
    /// Drives which overlay (spinner / error / replay) `PlayerView` shows.
    enum PlaybackState {
        /// Opening or buffering — no frames yet.
        case loading
        /// Playing or paused with frames available.
        case ready
        /// Playback failed (network, codec, bad stream).
        case failed
        /// Reached end of media.
        case ended
    }

    /// Current lifecycle state. Starts in `.loading` until VLC reports otherwise.
    @Published var playbackState: PlaybackState = .loading

    /// Mirrors the underlying player; drives the play/pause button label.
    @Published var isPlaying = false

    /// Read-only playback position, e.g. "01:23". "--:--" until known.
    @Published var currentTimeText = "--:--"

    /// Total media length, e.g. "24:10". "--:--" until parsed.
    @Published var durationText = "--:--"

    /// Fractional progress 0.0–1.0. Bound to the scrub slider, so it is also
    /// the drag value while scrubbing.
    @Published var progress: Double = 0

    /// True while the user drags the slider. Suppresses live progress updates
    /// so the thumb doesn't fight the playhead mid-drag.
    @Published var isScrubbing = false

    override init() {
        super.init()
        player.delegate = self
    }

    /// Load + auto-play the stream once a drawable is attached.
    func start(url: URL) {
        guard player.media == nil else { return }
        player.media = VLCMedia(url: url)
        player.play()
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func stop() {
        player.stop()
    }

    /// Restart from the beginning after the media ended. Used by the
    /// end-of-playback replay button.
    func replay() {
        playbackState = .loading
        player.stop()
        player.play()
    }

    // MARK: Seeking

    /// Called when the slider drag begins: freeze live progress updates.
    func beginScrubbing() {
        isScrubbing = true
    }

    /// Called when the slider drag ends: seek to the dragged fraction, then
    /// resume live updates. `fraction` clamped to 0.0–1.0.
    func endScrubbing(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if player.isSeekable {
            player.position = Float(clamped)
        }
        progress = clamped
        isScrubbing = false
    }

    /// Jump back `skipInterval` seconds. VLC clamps at the start.
    func skipBackward() {
        guard player.isSeekable else { return }
        player.jumpBackward(Self.skipInterval)
    }

    /// Jump forward `skipInterval` seconds. VLC clamps at the end.
    func skipForward() {
        guard player.isSeekable else { return }
        player.jumpForward(Self.skipInterval)
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        isPlaying = player.isPlaying
        updatePlaybackState()
        refreshTimes()
    }

    /// Collapse the granular `VLCMediaPlayerState` into our 4-case lifecycle.
    private func updatePlaybackState() {
        // If the player is actually playing, treat it as ready regardless of the
        // reported state. On device VLC can keep reporting `.buffering` (or only
        // `.esAdded`) while frames already render, which otherwise leaves the
        // "Buffering..." overlay stuck on top of live playback.
        if player.isPlaying {
            playbackState = .ready
            return
        }

        switch player.state {
        case .opening, .buffering:
            playbackState = .loading
        case .error:
            playbackState = .failed
        case .ended, .stopped:
            playbackState = .ended
        case .playing, .paused:
            playbackState = .ready
        default:
            // .esAdded and any future cases: keep current state.
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Time advancing means real playback is underway: clear any stale
        // loading overlay even if no `.playing` state notification arrived.
        if playbackState == .loading && player.isPlaying {
            playbackState = .ready
        }
        isPlaying = player.isPlaying
        refreshTimes()
    }

    /// Pull current time, duration, and fractional progress off the player.
    /// `VLCTime.stringValue` already formats as MM:SS (or HH:MM:SS).
    private func refreshTimes() {
        currentTimeText = player.time.stringValue ?? "--:--"

        if let length = player.media?.length, length.intValue > 0 {
            durationText = length.stringValue ?? "--:--"
        } else {
            durationText = "--:--"
        }

        // Don't move the slider thumb while the user is dragging it.
        guard !isScrubbing else { return }

        // player.position is 0.0–1.0; clamp NaN/out-of-range to a safe value.
        let pos = Double(player.position)
        progress = pos.isFinite ? min(max(pos, 0), 1) : 0
    }
}

/// Minimal SwiftUI wrapper around MobileVLCKit for formats AVPlayer cannot
/// handle (mkv, avi, webm). Streams `url` over the private Tailscale link.
///
/// Rendering only — playback control lives on the shared `controller`.
/// AVPlayer formats (mp4/mov/m4v) do NOT use this; see `PlayerView`.
struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    let controller: VLCPlayerController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        controller.player.drawable = container
        controller.start(url: url)

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-claim the drawable for whichever view is currently mounted.
        // A single `VLCMediaPlayer` renders into one drawable at a time, so when
        // the same controller is shared between the inline surface and the
        // fullScreenCover, the most recently presented view must take it back.
        // Idempotent: a no-op when this view already owns the drawable.
        if controller.player.drawable as? UIView !== uiView {
            controller.player.drawable = uiView
        }
    }
}
