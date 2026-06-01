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

    /// Last-watched fractional position (0.0–1.0) per video URL, kept for the
    /// life of the app session. The controller is a `@StateObject` on
    /// `PlayerView`, so it is destroyed and recreated each time the player
    /// screen is opened — instance state cannot survive that. This static store
    /// does, letting the same video resume where it left off. Cleared for a URL
    /// only when its playback truly ends (see `replay`/end handling).
    private static var savedPositions: [URL: Float] = [:]

    /// The URL currently loaded, captured in `start` so `stop` can persist the
    /// position against the right key without the call site passing it back.
    private var currentURL: URL?

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

    /// Fractional position to restore once the freshly-loaded media becomes
    /// seekable. Set in `start` from `savedPositions`; applied and cleared in the
    /// delegate callbacks. VLC ignores `player.position` writes before the stream
    /// is seekable, so the seek is deferred rather than done inline in `start`.
    private var pendingResume: Float?

    /// Load + auto-play the stream once a drawable is attached. If this URL was
    /// watched earlier in the session, resume from the saved position.
    func start(url: URL) {
        guard player.media == nil else { return }
        currentURL = url
        player.media = VLCMedia(url: url)

        if let saved = Self.savedPositions[url], saved > 0, saved < 1 {
            pendingResume = saved
        }

        player.play()
    }

    /// Apply a deferred resume seek once VLC reports the stream seekable. No-op
    /// when nothing is pending. Cleared after a successful seek so it fires once.
    private func applyPendingResumeIfReady() {
        guard let target = pendingResume, player.isSeekable else { return }
        player.position = target
        pendingResume = nil
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func stop() {
        persistPosition()
        player.stop()
    }

    /// Save the current fractional position for this session so reopening the
    /// same video resumes here. Skips meaningless values: not seekable, NaN/out
    /// of range, at the very start, or essentially at the end (treated as done).
    private func persistPosition() {
        guard let url = currentURL, player.isSeekable else { return }
        let pos = player.position
        guard pos.isFinite, pos > 0.001, pos < 0.999 else {
            Self.savedPositions[url] = nil
            return
        }
        Self.savedPositions[url] = pos
    }

    /// Restart from the beginning after the media ended. Used by the
    /// end-of-playback replay button.
    func replay() {
        if let url = currentURL { Self.savedPositions[url] = nil }
        pendingResume = nil
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
        applyPendingResumeIfReady()
        updatePlaybackState()

        // Reaching the end clears any saved position so a later open of this
        // video starts fresh rather than resuming at ~100%.
        if player.state == .ended, let url = currentURL {
            Self.savedPositions[url] = nil
        }

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
        // Stream is seekable by now; apply a deferred resume if one is pending.
        // Belt-and-braces alongside the state-changed hook: whichever fires
        // first while seekable wins, and the flag clears so it runs once.
        applyPendingResumeIfReady()

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

    /// True when this instance is the fullscreen surface. The inline surface and
    /// the `fullScreenCover` surface are mounted at the same time, both sharing
    /// one `controller` / `VLCMediaPlayer`, which can render into only ONE
    /// drawable. This flag decides ownership: when fullscreen is presented the
    /// fullscreen instance owns the drawable; otherwise the inline instance does.
    /// Without it, the inline view's `updateUIView` (fired on the cover's present
    /// relayout) would steal the drawable back and blank the fullscreen video.
    var isActiveSurface: Bool = true

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        if isActiveSurface {
            controller.player.drawable = container
        }
        controller.start(url: url)

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Only the active surface may own the drawable. This keeps the inline
        // instance from re-claiming it while the fullScreenCover is presented
        // (and vice versa). Idempotent: no-op when ownership already matches.
        guard isActiveSurface else { return }
        if controller.player.drawable as? UIView !== uiView {
            controller.player.drawable = uiView
        }
    }
}
