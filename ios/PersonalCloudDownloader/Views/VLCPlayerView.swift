import SwiftUI
import MobileVLCKit

/// Owns the `VLCMediaPlayer` for one playback screen and publishes its
/// play/pause state so SwiftUI controls can reflect it.
///
/// Shared between `VLCPlayerView` (sets drawable + media) and `PlayerView`
/// (renders the play/pause button + interactive seek slider). Step 6C scope
/// adds a scrub slider and ±10s skip — no full custom player UI.
final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    /// Every player is built from this ONE styled library so subtitle styling is
    /// applied — see `subtitleStyledLibrary` for why per-media options didn't work.
    let player = VLCMediaPlayer(library: VLCPlayerController.subtitleStyledLibrary)

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

    /// Professional, nPlayer-style fullscreen aspect modes. The cycle button
    /// steps through them in order. Implementation splits two families:
    ///   - `fit` / `zoom`: VLC `scaleFactor` (aspect-preserving, no distortion).
    ///   - `r16x9` / `r4x3` / `r1x1` / `stretch`: VLC `videoAspectRatio` string,
    ///     forcing a chosen display aspect (intentional, selectable ratios).
    /// `fit` is the safe default and must never make the picture look worse.
    /// NOTE: Aspect Fill ("Zoom") was removed. Native VLC subtitles cannot stay
    /// screen-stable with VLC crop Zoom or SwiftUI drawable scaling — both move
    /// the subtitle with the picture. A true nPlayer-style Aspect Fill with
    /// stable subtitles needs a separate subtitle overlay solution later.
    enum AspectMode: String, CaseIterable {
        case fit        // Whole video, letterboxed. Default.
        case r16x9      // Force 16:9 display aspect.
        case r4x3       // Force 4:3 display aspect.
        case r1x1       // Force 1:1 display aspect.
        case stretch    // Force the surface's aspect — intentional full-stretch.

        /// Short label shown on the cycle button.
        var label: String {
            switch self {
            case .fit: return "Fit"
            case .r16x9: return "16:9"
            case .r4x3: return "4:3"
            case .r1x1: return "1:1"
            case .stretch: return "Stretch"
            }
        }

        /// SF Symbol hint for the button.
        var icon: String {
            switch self {
            case .fit: return "rectangle.arrowtriangle.2.inward"
            case .stretch: return "arrow.up.left.and.arrow.down.right"
            default: return "aspectratio"
            }
        }

        /// Fixed "W:H" display aspect for the ratio modes; nil for fit/zoom
        /// (handled via scaleFactor) and for stretch (uses the surface ratio).
        var fixedAspect: (w: Int, h: Int)? {
            switch self {
            case .r16x9: return (16, 9)
            case .r4x3: return (4, 3)
            case .r1x1: return (1, 1)
            default: return nil
            }
        }

        /// Next mode in the cycle.
        var next: AspectMode {
            let all = Self.allCases
            let i = all.firstIndex(of: self)!
            return all[(i + 1) % all.count]
        }
    }

    /// Current scaling mode. Published so the fullscreen toggle reflects it.
    /// Default `.fit`. Only the fullscreen surface drives this; inline always
    /// renders default (Fit) because it never changes the mode.
    @Published var aspectMode: AspectMode = .fit

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

    // MARK: Subtitles

    /// One selectable subtitle track: VLC's internal SPU index and its label.
    /// Excludes VLC's synthetic "Disable" entry — that case is the dedicated
    /// "Off" choice in the picker, represented by `currentSubtitleIndex == -1`.
    struct SubtitleTrack: Identifiable {
        let index: Int32
        let name: String
        var id: Int32 { index }
    }

    /// Real (non-Disable) embedded subtitle tracks discovered after the media
    /// parses. Empty until tracks are known; drives whether the subtitle button
    /// is shown at all, so no broken UI appears when a video has no subtitles.
    @Published var subtitleTracks: [SubtitleTrack] = []

    /// Currently selected SPU index. `-1` means subtitles off. Mirrors
    /// `player.currentVideoSubTitleIndex` so the picker reflects reality.
    @Published var currentSubtitleIndex: Int32 = -1

    /// Convenience for the UI: only show the subtitle control when tracks exist.
    var hasSubtitles: Bool { !subtitleTracks.isEmpty }

    /// Guards the one-time auto-select: the first time real tracks are detected
    /// we turn the first track on, but only once, so a later manual "Off" sticks.
    /// Cleared on `start` / `replay` so a fresh load auto-selects again.
    private var didAutoSelectSubtitle = false

    override init() {
        super.init()
        player.delegate = self
    }

    /// Fractional position to restore once the freshly-loaded media becomes
    /// seekable. Set in `start` from `savedPositions`; applied and cleared in the
    /// delegate callbacks. VLC ignores `player.position` writes before the stream
    /// is seekable, so the seek is deferred rather than done inline in `start`.
    private var pendingResume: Float?

    /// ONE shared, subtitle-styled `VLCLibrary`, built lazily on first use and
    /// reused by every `VLCMediaPlayer` this class creates (inline + fullscreen).
    ///
    /// WHY A LIBRARY, NOT PER-MEDIA OPTIONS: the FreeType subtitle renderer reads
    /// its `freetype-*` options when the libVLC instance (the `VLCLibrary`)
    /// initializes — they are module/output options, not demux/input options.
    /// `VLCMedia.addOptions(...)` only attaches INPUT options to that one media,
    /// so the renderer never saw the `freetype-*` keys and silently used its
    /// defaults (rel-fontsize ≈ 16 → height/16 → huge text). That is why every
    /// previous size/outline change "did nothing" on device. Passing them as
    /// libVLC init arguments here is the place the renderer actually reads.
    ///
    /// Options use the real CLI form (`--name=value`), which `VLCLibrary(options:)`
    /// expects (NOT the bare keys the per-media dict API took):
    ///   - `--freetype-rel-fontsize=22`    size = video-height / 22 → readable
    ///     cinema text, resolution-independent (bigger divisor = smaller text).
    ///   - `--freetype-color=16777215`     white text.
    ///   - `--freetype-opacity=255`        opaque text.
    ///   - `--freetype-outline-thickness=1` thin black outline (nPlayer-like).
    ///   - `--freetype-outline-color=0`    black outline.
    ///   - `--freetype-outline-opacity=255` solid outline.
    ///   - `--freetype-shadow-opacity=0`   no drop shadow (outline carries it).
    ///   - `--freetype-background-opacity=0` NO black box behind text.
    /// Center-bottom placement and the small bottom gap are libVLC defaults, so
    /// they are not forced. `sub-margin` is an INPUT option, so it stays per-media
    /// (see `start`) — it is the one subtitle option that DOES belong on the media.
    static let subtitleStyledLibrary: VLCLibrary = VLCLibrary(options: [
        "--freetype-rel-fontsize=22",
        "--freetype-color=16777215",
        "--freetype-opacity=255",
        "--freetype-outline-thickness=1",
        "--freetype-outline-color=0",
        "--freetype-outline-opacity=255",
        "--freetype-shadow-opacity=0",
        "--freetype-background-opacity=0",
    ])

    /// Load + auto-play the stream once a drawable is attached. If this URL was
    /// watched earlier in the session, resume from the saved position.
    func start(url: URL) {
        guard player.media == nil else { return }
        currentURL = url
        let media = VLCMedia(url: url)
        // `sub-margin` is an INPUT option (lifts subtitles off the very bottom so
        // they clear the controls/scrim), so it belongs on the media — unlike the
        // renderer `freetype-*` options, which live on the styled library above.
        media.addOptions(["sub-margin": 48])
        player.media = media

        if let saved = Self.savedPositions[url], saved > 0, saved < 1 {
            pendingResume = saved
        }

        didAutoSelectSubtitle = false
        subtitleTracks = []
        currentSubtitleIndex = -1

        player.play()
    }

    /// Apply a deferred resume seek once VLC reports the stream seekable. No-op
    /// when nothing is pending. Cleared after a successful seek so it fires once.
    private func applyPendingResumeIfReady() {
        guard let target = pendingResume, player.isSeekable else { return }
        player.position = target
        pendingResume = nil
    }

    // MARK: Drawable ownership

    /// The view currently wired as the player's video output. Tracked so a
    /// dismantled (dormant) surface only detaches if it still owns the drawable,
    /// never clearing one a newly-mounted surface has already claimed.
    private weak var attachedDrawable: UIView?

    /// Make `view` the player's video output. Called from `makeUIView` when a
    /// surface mounts. Only ONE VLC surface is mounted at a time (inline OR
    /// fullscreen, never both — see `PlayerView`), so this is an unconditional
    /// hand-off: the freshly mounted view always becomes the drawable.
    func attachDrawable(_ view: UIView) {
        player.drawable = view
        attachedDrawable = view
    }

    /// Release `view` as the drawable when its surface is dismantled. Guarded so
    /// a stale teardown cannot clear a drawable that a later surface already
    /// owns. Leaves the player (and audio) alive — only the video output detaches.
    func detachDrawable(_ view: UIView) {
        guard attachedDrawable === view else { return }
        player.drawable = nil
        attachedDrawable = nil
    }

    // MARK: Aspect / scaling

    /// The fullscreen surface size, retained so Zoom can be re-applied once the
    /// video track is parsed (crop/aspect set too early can be dropped by VLC).
    /// Set on every `cycleAspect` / `applyAspect` call.
    private var aspectDrawableSize: CGSize = .zero

    /// Whether the current mode has been applied with the video track parsed.
    /// Cleared whenever the mode changes; set by `reapplyAspectIfNeeded` so the
    /// per-frame retry runs only until it succeeds once.
    private var aspectApplied = false

    /// Advance to the next mode and apply it. `drawableSize` is the current
    /// fullscreen surface, used for the Zoom and Stretch math. Called from the
    /// fullscreen ratio button.
    func cycleAspect(drawableSize: CGSize) {
        aspectMode = aspectMode.next
        aspectApplied = false
        applyAspect(drawableSize: drawableSize)
    }

    /// Apply `aspectMode`. Distinct families, never stacked — every call first
    /// resets scaleFactor, videoAspectRatio AND videoCropGeometry:
    ///   - `fit`:    everything cleared → whole video, letterboxed (default).
    ///   - `r16x9` / `r4x3` / `r1x1`: videoAspectRatio = fixed "W:H" string.
    ///   - `stretch`: videoAspectRatio = the surface's ratio → full stretch.
    /// The aspect-ratio strings can be ignored if set before the video track is
    /// parsed, so `reapplyAspectIfNeeded` re-applies once playback is underway.
    ///
    /// NO ZOOM / ASPECT FILL: neither VLC `videoCropGeometry` nor a SwiftUI
    /// `scaleEffect` on the drawable can fill the screen while keeping native
    /// subtitles screen-stable — both move the subtitle with the picture. Zoom
    /// was removed; only aspect-preserving / fixed-ratio modes remain, which do
    /// not disturb the subtitle anchor. A real nPlayer-style Aspect Fill with
    /// stable subtitles needs a separate subtitle overlay solution later.
    func applyAspect(drawableSize: CGSize) {
        aspectDrawableSize = drawableSize

        // Clean slate so modes don't combine. Crop is never used now, but clear
        // it defensively in case an older media set it.
        player.scaleFactor = 0
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil

        switch aspectMode {
        case .fit:
            break // defaults above

        case .r16x9, .r4x3, .r1x1:
            if let r = aspectMode.fixedAspect {
                setCString("\(r.w):\(r.h)") { player.videoAspectRatio = $0 }
            }

        case .stretch:
            let w = Int(drawableSize.width.rounded())
            let h = Int(drawableSize.height.rounded())
            guard w > 0, h > 0 else { return }
            setCString("\(w):\(h)") { player.videoAspectRatio = $0 }
        }
    }

    /// Re-apply the current mode once playback is underway. Aspect strings set
    /// before the video track is parsed can be dropped by VLC; re-applying after
    /// the first frames (when `videoSize` is known) makes them reliable.
    /// Harmless for fixed-ratio / stretch modes.
    private func reapplyAspectIfNeeded() {
        guard !aspectApplied, aspectDrawableSize != .zero, aspectMode != .fit else { return }
        // videoSize becoming non-zero signals the track is parsed.
        let v = player.videoSize
        guard v.width > 0, v.height > 0 else { return }
        applyAspect(drawableSize: aspectDrawableSize)
        aspectApplied = true
    }

    /// Hand a freshly-duplicated C string to a VLC setter. VLC copies the value,
    /// so the duplicate is freed immediately after the setter returns.
    private func setCString(_ value: String, _ setter: (UnsafeMutablePointer<CChar>?) -> Void) {
        value.withCString { src in
            let dup = strdup(src)
            setter(dup)
            free(dup)
        }
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

    /// Fully release this controller's playback: persist position, stop audio,
    /// detach the drawable, and drop the media so a later `start` reloads from
    /// scratch. Used when handing playback OFF to a separate controller (inline
    /// → fullscreen and back) so two VLC players never run audio at once, and so
    /// the reclaiming controller can re-`start` cleanly. Position survives via
    /// the shared `savedPositions` store, keyed by URL.
    func teardown() {
        persistPosition()
        player.stop()
        if let view = attachedDrawable {
            detachDrawable(view)
        }
        player.media = nil
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
        didAutoSelectSubtitle = false
        playbackState = .loading
        player.stop()
        player.play()
    }

    // MARK: Subtitles

    /// Read the player's current SPU track list and refresh `subtitleTracks`.
    /// VLC exposes parallel arrays — `videoSubTitlesIndexes` (NSNumber SPU ids)
    /// and `videoSubTitlesNames` (labels) — and includes a synthetic "Disable"
    /// entry at index `-1`, which we drop (it's the dedicated "Off" choice).
    /// Tracks only become known after the media parses, so this is called from
    /// the time-changed delegate; it's idempotent and cheap to re-run.
    ///
    /// The first time real tracks appear, auto-select the first so embedded
    /// subtitles show without the user hunting for a control (done once, guarded
    /// by `didAutoSelectSubtitle`, so a later manual "Off" is respected).
    private func refreshSubtitleTracks() {
        let indexes = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let names = player.videoSubTitlesNames.compactMap { $0 as? String }
        guard indexes.count == names.count else { return }

        let tracks = zip(indexes, names)
            .filter { $0.0 >= 0 } // drop the synthetic "Disable" (-1) entry
            .map { SubtitleTrack(index: $0.0, name: $0.1) }

        if tracks.map(\.index) != subtitleTracks.map(\.index) {
            subtitleTracks = tracks
        }

        if !didAutoSelectSubtitle, let first = tracks.first {
            didAutoSelectSubtitle = true
            selectSubtitle(index: first.index)
        }

        currentSubtitleIndex = player.currentVideoSubTitleIndex
    }

    /// Select an SPU track by VLC index, or pass `-1` to turn subtitles off.
    /// Called by the picker and by the one-time auto-select.
    func selectSubtitle(index: Int32) {
        player.currentVideoSubTitleIndex = index
        currentSubtitleIndex = index
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

        // Video size is known now; recompute Fill zoom if it was deferred.
        reapplyAspectIfNeeded()

        // SPU tracks are parsed by now; pick them up and auto-select once.
        refreshSubtitleTracks()

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

    /// Exactly one `VLCPlayerView` is mounted at a time — the inline surface OR
    /// the fullscreen surface, never both (`PlayerView` swaps the inline view for
    /// a black placeholder while the cover is up). So mounting always claims the
    /// drawable and dismantling releases it, giving a clean hand-off on
    /// fullscreen open/close instead of two live views fighting over one player.
    /// Holds the controller reference so the static `dismantleUIView` can detach
    /// the drawable when this surface unmounts.
    final class Coordinator {
        let controller: VLCPlayerController
        init(_ controller: VLCPlayerController) { self.controller = controller }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        controller.attachDrawable(container)
        controller.start(url: url)

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-assert ownership in case a relayout left the drawable detached.
        // No-op when this view already owns it.
        if controller.player.drawable as? UIView !== uiView {
            controller.attachDrawable(uiView)
        }
    }

    /// Release the drawable when this surface unmounts (switching to/from the
    /// fullscreen surface). The player keeps running; only the video output
    /// detaches, so the next-mounted surface can claim it cleanly.
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.controller.detachDrawable(uiView)
    }
}
