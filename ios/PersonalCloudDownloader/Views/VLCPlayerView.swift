import SwiftUI
import AVFoundation
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

    /// Last-watched playback position per stable video key. Kept in memory for
    /// inline ⇄ fullscreen hand-off and mirrored to UserDefaults so it survives
    /// app updates installed in place. A full delete/reinstall wipes iOS local
    /// app storage; true persistence across that needs backend/server storage.
    ///
    /// Stored as MILLISECONDS (+ duration), not a `Float` fraction: the inline ⇄
    /// fullscreen hand-off persists and restores through here, and a `Float`
    /// fraction loses seconds on long videos (e.g. a 2h film: one ULP of a
    /// `Float` near 0.5 is ~0.4s, and the cumulative rounding through
    /// fraction→seek→fraction drifts the resume point). Milliseconds restore the
    /// exact playhead. Duration is kept so a precise fractional fallback can be
    /// derived when a millisecond seek isn't yet possible.
    struct SavedPosition: Codable {
        let timeMs: Int
        let durationMs: Int
        /// Fractional position, for the deferred `player.position` fallback.
        var fraction: Float {
            durationMs > 0 ? Float(timeMs) / Float(durationMs) : 0
        }
    }
    private static let savedPositionsDefaultsKey = "vlc.savedPlaybackPositions.v1"
    private static var savedPositions: [String: SavedPosition] = loadSavedPositions()
    private static let savedPreferencesDefaultsKey = "vlc.playerPreferences.v1"
    private static var savedPreferences: [String: PlayerPreference] = loadSavedPreferences()

    /// The key currently loaded, captured in `start` so `stop` can persist the
    /// position against the right key without the call site passing it back.
    /// Prefer `CompletedFile.path`, because URL host/encoding can change.
    private var currentResumeKey: String?

    private var lastPeriodicPersistMs = 0

    private struct PlayerPreference: Codable {
        var aspectMode: AspectMode? = nil
        var subtitle: SubtitlePreference? = nil
    }

    private enum SubtitlePreference: Codable, Equatable {
        case sidecar
        case embedded(name: String, fallbackIndex: Int32)
        case off
    }

    private var savedSubtitlePreference: SubtitlePreference?
    private var didApplySavedSubtitlePreference = false

    private static func normalizeResumeKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadSavedPositions() -> [String: SavedPosition] {
        guard let data = UserDefaults.standard.data(forKey: savedPositionsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: SavedPosition].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func writeSavedPositions() {
        guard let data = try? JSONEncoder().encode(savedPositions) else { return }
        UserDefaults.standard.set(data, forKey: savedPositionsDefaultsKey)
    }

    private static func loadSavedPreferences() -> [String: PlayerPreference] {
        guard let data = UserDefaults.standard.data(forKey: savedPreferencesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: PlayerPreference].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func writeSavedPreferences() {
        guard let data = try? JSONEncoder().encode(savedPreferences) else { return }
        UserDefaults.standard.set(data, forKey: savedPreferencesDefaultsKey)
    }

    private func updatePreference(_ update: (inout PlayerPreference) -> Void) {
        guard let key = currentResumeKey else {
            print("[VLC_PREF] save skipped: no resume key (controller \(ObjectIdentifier(self)))")
            return
        }
        var preference = Self.savedPreferences[key] ?? PlayerPreference()
        update(&preference)
        Self.savedPreferences[key] = preference
        Self.writeSavedPreferences()
        // TEMPORARY diagnostic — remove once ratio/subtitle memory is verified on device.
        print("[VLC_PREF] save key=\(key) aspect=\(preference.aspectMode?.rawValue ?? "nil") subtitle=\(String(describing: preference.subtitle)) controller=\(ObjectIdentifier(self))")
    }

    private static func savePosition(_ position: SavedPosition, for key: String) {
        savedPositions[key] = position
        writeSavedPositions()
        Task {
            try? await CompletedFilesAPI.saveVideoProgress(
                path: key,
                timeMs: position.timeMs,
                durationMs: position.durationMs
            )
        }
    }

    private static func clearPosition(for key: String) {
        savedPositions[key] = nil
        writeSavedPositions()
    }

    static func localProgressSnapshot() -> [String: VideoProgress] {
        Dictionary(uniqueKeysWithValues: savedPositions.map { key, position in
            (
                key,
                VideoProgress.local(
                    path: key,
                    timeMs: position.timeMs,
                    durationMs: position.durationMs
                )
            )
        })
    }

    static func importProgressSnapshot(_ progressByPath: [String: VideoProgress]) {
        for (path, progress) in progressByPath {
            guard progress.timeMs > 0, progress.durationMs > 0 else { continue }
            savedPositions[path] = SavedPosition(
                timeMs: progress.timeMs,
                durationMs: progress.durationMs
            )
        }
        writeSavedPositions()
    }

    /// The two fullscreen scaling modes the ratio button toggles between.
    /// Deliberately minimal — no 16:9 / 4:3 / 1:1 / Stretch — for a clean,
    /// professional Fit ⇄ Cover behavior like nPlayer.
    ///   - `fit`:   whole video, original ratio, letterboxed (black bars OK).
    ///   - `cover`: Aspect Fill — fill the fullscreen area, keep the original
    ///     ratio (no stretch), crop the overflowing edges. Implemented with VLC
    ///     `videoCropGeometry` set to the surface aspect, which is the cleanest
    ///     true cover. NOTE: cropping moves VLC's subtitle anchor, so subtitles
    ///     can shift in Cover — accepted for now (Cover correctness prioritized);
    ///     a stable-subtitle Aspect Fill needs a separate overlay later.
    enum AspectMode: String, CaseIterable, Codable {
        case fit
        case cover

        /// Short label shown on the toggle button.
        var label: String {
            switch self {
            case .fit: return "Fit"
            case .cover: return "Cover"
            }
        }

        /// SF Symbol hint for the button.
        var icon: String {
            switch self {
            case .fit: return "rectangle.arrowtriangle.2.inward"
            case .cover: return "rectangle.arrowtriangle.2.outward"
            }
        }

        /// Next mode in the toggle (Fit ⇄ Cover).
        var next: AspectMode {
            self == .fit ? .cover : .fit
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

    /// Time remaining, formatted like "-08:08" for the fullscreen top bar.
    /// Read-only display value derived from the player clock — no effect on
    /// playback. "--:--" until both current time and duration are known.
    @Published var remainingTimeText = "--:--"

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

    // MARK: Audio tracks

    /// One selectable VLC audio track: VLC's internal index and display label.
    struct AudioTrack: Identifiable {
        let index: Int32
        let name: String
        var id: Int32 { index }
    }

    /// Real audio tracks discovered after media parses.
    @Published var audioTracks: [AudioTrack] = []

    /// Currently selected VLC audio track index.
    @Published var currentAudioTrackIndex: Int32 = -1

    /// Only show the audio control when there is an actual choice.
    var hasSelectableAudioTracks: Bool { audioTracks.count > 1 }

    // MARK: Sidecar (.srt) subtitle overlay — Phase A

    /// Parsed cues from a sidecar `.srt` fetched beside the video, empty when no
    /// sidecar was found. When present, these drive a SwiftUI overlay that stays
    /// screen-stable in Cover mode (native VLC subtitles shift with the crop).
    private var sidecarCues: [SRTCue] = []

    /// True once a sidecar `.srt` was found and parsed for the current video.
    /// When true the UI uses the overlay as the SOLE subtitle source and native
    /// VLC SPU is kept off, so the picker is a simple Subtitles/Off toggle.
    @Published var hasSidecarSubtitle = false

    /// Whether the sidecar overlay is currently shown. The picker's "Off" sets
    /// this false; selecting "Subtitles" sets it true. Only meaningful when
    /// `hasSidecarSubtitle` is true. Defaults on so found subtitles auto-show.
    @Published var sidecarEnabled = true

    /// The cue text to render right now, or nil when no cue is active / overlay
    /// off. Updated from the existing time-change delegate, so no extra timer.
    @Published var currentSubtitleText: String?

    /// Tracks the in-flight sidecar fetch so a teardown/reload can ignore a late
    /// response for a previous URL.
    private var sidecarFetchURL: URL?

    override init() {
        super.init()
        player.delegate = self
    }

    /// Position to restore once the freshly-loaded media becomes seekable. Set in
    /// `start` from path-keyed `savedPositions`; applied and cleared in the delegate
    /// callbacks. VLC ignores seek writes before the stream is seekable, so the
    /// seek is deferred rather than done inline in `start`. Carries milliseconds
    /// so the playhead is restored exactly (a `VLCTime` seek), with the fraction
    /// kept for the rare case the duration isn't known yet at seek time.
    private var pendingResume: SavedPosition?

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

    /// Load + auto-play the stream once a drawable is attached. If this video
    /// was watched earlier, resume from its saved position.
    func start(url: URL, resumeKey: String) {
        guard player.media == nil else { return }
        let stableKey = Self.normalizeResumeKey(resumeKey)
        currentResumeKey = stableKey.isEmpty ? url.absoluteString : stableKey
        lastPeriodicPersistMs = 0
        let media = VLCMedia(url: url)
        // `sub-margin` is an INPUT option (lifts subtitles off the very bottom so
        // they clear the controls/scrim), so it belongs on the media — unlike the
        // renderer `freetype-*` options, which live on the styled library above.
        media.addOptions(["sub-margin": 48])
        player.media = media

        if let key = currentResumeKey,
           let saved = Self.savedPositions[key],
           saved.timeMs > 0 {
            pendingResume = saved
        }
        let savedPreference = currentResumeKey.flatMap { Self.savedPreferences[$0] }
        aspectMode = savedPreference?.aspectMode ?? .fit
        aspectApplied = false
        savedSubtitlePreference = savedPreference?.subtitle
        didApplySavedSubtitlePreference = false
        // TEMPORARY diagnostic — remove once ratio/subtitle memory is verified on device.
        print("[VLC_PREF] load key=\(currentResumeKey ?? "nil") found=\(savedPreference != nil) aspect=\(savedPreference?.aspectMode?.rawValue ?? "nil") subtitle=\(String(describing: savedPreference?.subtitle)) controller=\(ObjectIdentifier(self))")

        didAutoSelectSubtitle = false
        subtitleTracks = []
        currentSubtitleIndex = -1
        audioTracks = []
        currentAudioTrackIndex = -1

        // Reset sidecar state and look for a `.srt` beside the video.
        sidecarCues = []
        hasSidecarSubtitle = false
        sidecarEnabled = savedSubtitlePreference != .off
        currentSubtitleText = nil
        fetchSidecarSubtitle(for: url)

        activateAudioSession()
        player.play()
    }

    /// Own the audio session instead of relying on MobileVLCKit's internal
    /// management: VLC deactivates the shared session on `stop()`, and the
    /// fullscreen⇄inline hand-off runs the new controller's `start` BEFORE the
    /// old controller's teardown, so that deactivation can land under live
    /// playback and leave audio muted/broken. Re-asserting `.playback` +
    /// active here on every `start` makes each (re)start begin with a valid,
    /// active session. No matching deactivation on exit — deliberate, so a
    /// late `stop()` from a dying controller can't kill the next player's audio.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal: playback still starts; VLC's internal session
            // handling remains the fallback if activation is refused.
        }
    }

    /// Try to fetch and parse a sidecar `.srt` beside the video — e.g.
    /// `…/Movie.mkv` → `…/Movie.srt`. Served by Nginx `/files/` with no backend
    /// change. On success the cues feed the SwiftUI overlay and native VLC SPU
    /// is turned off (overlay is the sole source).
    ///
    /// If the sidecar is missing (404), ask the backend to extract an embedded
    /// text subtitle track into that `.srt` (see `requestSubtitleExtraction`),
    /// then retry the fetch ONCE. On any failure (no file, no text track, no
    /// ffmpeg, network, parse) the app silently keeps native embedded-subtitle
    /// behavior — no error UI.
    private func fetchSidecarSubtitle(for videoURL: URL) {
        let srtURL = videoURL.deletingPathExtension().appendingPathExtension("srt")
        sidecarFetchURL = srtURL
        fetchSidecarData(srtURL: srtURL, videoURL: videoURL, allowExtraction: true)
    }

    func searchMissingSubtitle(for videoURL: URL, completion: @escaping (String) -> Void) {
        guard let endpoint = backendSubtitleURL(for: videoURL, path: "/api/subtitles/search"),
              let relativePath = filesRelativePath(of: videoURL) else {
            completion("invalid_path")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": relativePath])

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String else {
                completion("provider_unavailable")
                return
            }

            if status == "found" || status == "exists" {
                DispatchQueue.main.async {
                    self.fetchSidecarData(
                        srtURL: videoURL.deletingPathExtension().appendingPathExtension("srt"),
                        videoURL: videoURL,
                        allowExtraction: false
                    )
                }
            }
            completion(status)
        }
        task.resume()
    }

    /// GET the `.srt`. 200 → activate overlay. 404 with `allowExtraction` →
    /// trigger a backend extract then retry once (extraction disabled on the
    /// retry so it can't loop). Anything else → silent native fallback.
    private func fetchSidecarData(srtURL: URL, videoURL: URL, allowExtraction: Bool) {
        let task = URLSession.shared.dataTask(with: srtURL) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 200, let data, let raw = String(data: data, encoding: .utf8) {
                self.activateSidecar(raw: raw, srtURL: srtURL)
                return
            }

            // Missing sidecar: try a one-shot server-side extraction, then retry.
            if status == 404, allowExtraction {
                self.requestSubtitleExtraction(for: videoURL) { created in
                    guard created else { return } // no_text_subtitles / failed → native
                    // Only retry if the player hasn't moved on to another video.
                    DispatchQueue.main.async {
                        guard self.sidecarFetchURL == srtURL else { return }
                        self.fetchSidecarData(srtURL: srtURL, videoURL: videoURL, allowExtraction: false)
                    }
                }
            }
        }
        task.resume()
    }

    /// Parse + activate sidecar cues on the main actor. Guarded so a response
    /// for a previous video is ignored.
    private func activateSidecar(raw: String, srtURL: URL) {
        let cues = SRTSubtitleParser.parse(raw)
        guard !cues.isEmpty else { return }
        DispatchQueue.main.async {
            guard self.sidecarFetchURL == srtURL else { return }
            self.sidecarCues = cues
            self.hasSidecarSubtitle = true
            // Overlay is the sole subtitle source: keep native VLC SPU off.
            self.player.currentVideoSubTitleIndex = -1
            self.currentSubtitleIndex = -1
            self.applySavedSubtitlePreferenceIfPossible()
            self.updateCurrentCue()
        }
    }

    /// Ask the backend to extract an embedded text subtitle track into the
    /// sidecar `.srt`. Derives the backend URL from the video URL: same scheme +
    /// host, the FastAPI port (8000), endpoint `/api/subtitles/extract`. The
    /// request body's `path` is the video path relative to the Nginx `/files/`
    /// root (the components after the `files` segment). `completion(true)` only
    /// when the server reports the `.srt` now exists (`extracted` / `exists`);
    /// every other status or any failure → `completion(false)` → native
    /// fallback. Nothing is hardcoded to a specific file or host.
    private func requestSubtitleExtraction(for videoURL: URL, completion: @escaping (Bool) -> Void) {
        guard let endpoint = backendExtractURL(for: videoURL),
              let relativePath = filesRelativePath(of: videoURL) else {
            completion(false)
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": relativePath])

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String else {
                completion(false)
                return
            }
            completion(status == "extracted" || status == "exists")
        }
        task.resume()
    }

    /// Backend extract endpoint URL: the video URL's scheme + host with the
    /// FastAPI port (8000) and the fixed path. Returns nil if the host is
    /// unknown.
    private func backendExtractURL(for videoURL: URL) -> URL? {
        backendSubtitleURL(for: videoURL, path: "/api/subtitles/extract")
    }

    private func backendSubtitleURL(for videoURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: videoURL, resolvingAgainstBaseURL: false),
              components.host != nil else { return nil }
        components.port = 8000
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The video path relative to the Nginx `/files/` root — the path the
    /// backend expects in the extract request. Takes the path components after
    /// the first `files` segment, e.g. `/files/Show/Ep.mkv` → `Show/Ep.mkv`.
    /// Returns nil if there is no `files` segment.
    private func filesRelativePath(of videoURL: URL) -> String? {
        let parts = videoURL.pathComponents.filter { $0 != "/" }
        guard let filesIdx = parts.firstIndex(of: "files"), filesIdx + 1 < parts.count else {
            return nil
        }
        return parts[(filesIdx + 1)...].joined(separator: "/")
    }

    /// Recompute the active sidecar cue from the player's current time. Cheap;
    /// driven by the existing time-change delegate, so no separate timer.
    private func updateCurrentCue() {
        guard hasSidecarSubtitle, sidecarEnabled else {
            if currentSubtitleText != nil { currentSubtitleText = nil }
            return
        }
        let timeMs = Int(player.time.intValue)
        let text = SRTSubtitleParser.cue(at: timeMs, in: sidecarCues)?.text
        if text != currentSubtitleText { currentSubtitleText = text }
    }

    /// Toggle the sidecar overlay on/off from the picker. Keeps native SPU off
    /// either way (overlay is the only subtitle source when a sidecar exists).
    func setSidecarEnabled(_ on: Bool) {
        // Manual toggle supersedes any pending saved-preference restore.
        didApplySavedSubtitlePreference = true
        sidecarEnabled = on
        if on {
            player.currentVideoSubTitleIndex = -1
            currentSubtitleIndex = -1
            updatePreference { $0.subtitle = .sidecar }
        } else if currentSubtitleIndex == -1 {
            updatePreference { $0.subtitle = .off }
        }
        updateCurrentCue()
    }

    /// Apply a deferred resume seek once VLC reports the stream seekable. No-op
    /// when nothing is pending. Cleared after a successful seek so it fires once.
    ///
    /// Seeks by absolute MILLISECONDS (`VLCTime`) so the playhead lands exactly
    /// where it was — this is the inline ⇄ fullscreen hand-off, where a fraction
    /// round-trip would drift the resume point. Falls back to the fractional
    /// `player.position` only if the stored duration is unknown (so no exact
    /// millisecond target exists).
    private func applyPendingResumeIfReady() {
        guard let target = pendingResume, player.isSeekable else { return }
        if target.durationMs > 0 {
            player.time = VLCTime(int: Int32(target.timeMs))
        } else {
            player.position = target.fraction
        }
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

    /// Toggle Fit ⇄ Cover and apply. `drawableSize` is the current real-landscape
    /// fullscreen surface size, used as the crop aspect for Cover. Called from
    /// the fullscreen ratio button.
    func cycleAspect(drawableSize: CGSize) {
        aspectMode = aspectMode.next
        updatePreference { $0.aspectMode = aspectMode }
        aspectApplied = false
        applyAspect(drawableSize: drawableSize)
    }

    /// Apply `aspectMode`. Every call first resets to a clean slate so modes
    /// never stack:
    ///   - `fit`:   everything cleared → whole video, original ratio, letterboxed.
    ///   - `cover`: `videoCropGeometry` = the surface's "W:H" → true Aspect Fill.
    ///     VLC crops the SOURCE to the surface aspect, then fits the crop to the
    ///     drawable: fills the screen, preserves the video's own ratio (no
    ///     stretch), crops the overflowing edges. Independent of `videoSize`.
    /// The crop string can be ignored if set before the video track is parsed,
    /// so `reapplyAspectIfNeeded` re-applies it once playback is underway.
    ///
    /// SUBTITLE NOTE: VLC crop moves the subtitle anchor, so native subtitles
    /// may shift in Cover. Accepted for now — Cover correctness is prioritized.
    /// A stable-subtitle Aspect Fill needs a separate subtitle overlay later.
    func applyAspect(drawableSize: CGSize) {
        aspectDrawableSize = drawableSize

        // Clean slate so Fit and Cover never combine.
        player.scaleFactor = 0
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil

        switch aspectMode {
        case .fit:
            break // defaults above

        case .cover:
            // Crop the source to the on-screen surface aspect → Aspect Fill.
            let w = Int(drawableSize.width.rounded())
            let h = Int(drawableSize.height.rounded())
            guard w > 0, h > 0 else { return }
            setCString("\(w):\(h)") { player.videoCropGeometry = $0 }
        }
    }

    /// Record the fullscreen surface size so a RESTORED aspect mode can reach
    /// the renderer without a ratio-button press (`cycleAspect` was previously
    /// the only place `aspectDrawableSize` was ever set, so a restored Cover
    /// changed the button label but never the video). Called from the
    /// fullscreen view's onAppear and again when the landscape rotation
    /// settles; the actual apply still defers via `reapplyAspectIfNeeded`
    /// until VLC has parsed the video track.
    func updateAspectDrawableSize(_ size: CGSize) {
        guard size != .zero, size != aspectDrawableSize else { return }
        aspectDrawableSize = size
        aspectApplied = false
        reapplyAspectIfNeeded()
    }

    /// Re-apply the current mode once playback is underway. The crop string set
    /// before the video track is parsed can be dropped by VLC; re-applying after
    /// the first frames (when `videoSize` is non-zero) makes Cover reliable.
    private func reapplyAspectIfNeeded() {
        guard !aspectApplied, aspectDrawableSize != .zero, aspectMode != .fit else { return }
        // videoSize becoming non-zero signals the track is parsed.
        let v = player.videoSize
        guard v.width > 0, v.height > 0 else { return }
        applyAspect(drawableSize: aspectDrawableSize)
        aspectApplied = true
        // TEMPORARY diagnostic — remove once ratio/subtitle memory is verified on device.
        print("[VLC_PREF] aspect applied mode=\(aspectMode.rawValue) surface=\(Int(aspectDrawableSize.width))x\(Int(aspectDrawableSize.height))")
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

    private func persistPositionIfNeeded() {
        let timeMs = Int(player.time.intValue)
        guard abs(timeMs - lastPeriodicPersistMs) >= 5_000 else { return }
        lastPeriodicPersistMs = timeMs
        persistPosition()
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
    /// the shared `savedPositions` store, keyed by stable video path.
    func teardown() {
        persistPosition()
        player.stop()
        if let view = attachedDrawable {
            detachDrawable(view)
        }
        player.media = nil
    }

    /// Save the current playback position (milliseconds + duration) for this
    /// session so reopening the same video — or handing off inline ⇄ fullscreen
    /// — resumes at the exact playhead. Skips meaningless values: not seekable,
    /// NaN/out of range, at the very start, or essentially at the end (treated as
    /// done). Public so the fullscreen close button can persist SYNCHRONOUSLY
    /// before the cover dismisses: SwiftUI remounts the inline surface (which
    /// re-`start`s and reads path-keyed `savedPositions`) before this controller's
    /// `onDisappear` runs, so persisting only in `teardown`/`onDisappear` would
    /// let inline resume from the stale pre-fullscreen position. Idempotent —
    /// safe to call again from `teardown`.
    func persistPosition() {
        guard let key = currentResumeKey, player.isSeekable else { return }
        let pos = player.position
        guard pos.isFinite, pos > 0.001, pos < 0.999 else {
            Self.clearPosition(for: key)
            return
        }
        let timeMs = Int(player.time.intValue)
        let durationMs = Int(player.media?.length.intValue ?? 0)
        Self.savePosition(SavedPosition(timeMs: timeMs, durationMs: durationMs), for: key)
    }

    /// Restart from the beginning after the media ended. Used by the
    /// end-of-playback replay button.
    func replay() {
        if let key = currentResumeKey { Self.clearPosition(for: key) }
        pendingResume = nil
        didAutoSelectSubtitle = false
        audioTracks = []
        currentAudioTrackIndex = -1
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

        applySavedSubtitlePreferenceIfPossible()

        // Sidecar remains the default when present, but embedded tracks stay
        // selectable in the menu.
        if savedSubtitlePreference == nil, !hasSidecarSubtitle, !didAutoSelectSubtitle, let first = tracks.first {
            didAutoSelectSubtitle = true
            selectSubtitle(index: first.index)
        }

        currentSubtitleIndex = player.currentVideoSubTitleIndex
    }

    /// Select an SPU track by VLC index, or pass `-1` to turn subtitles off.
    /// Called by the picker and by the one-time auto-select.
    func selectSubtitle(index: Int32) {
        // A manual choice supersedes any still-pending saved-preference restore
        // (e.g. a slow sidecar arriving later must not override it).
        didApplySavedSubtitlePreference = true
        player.currentVideoSubTitleIndex = index
        currentSubtitleIndex = index
        if index == -1 {
            updatePreference { $0.subtitle = .off }
        }
    }

    func selectSubtitle(track: SubtitleTrack) {
        didApplySavedSubtitlePreference = true
        player.currentVideoSubTitleIndex = track.index
        currentSubtitleIndex = track.index
        updatePreference { $0.subtitle = .embedded(name: track.name, fallbackIndex: track.index) }
    }

    private func applySavedSubtitlePreferenceIfPossible() {
        guard !didApplySavedSubtitlePreference, let preference = savedSubtitlePreference else { return }

        switch preference {
        case .sidecar:
            guard hasSidecarSubtitle else { return }
            sidecarEnabled = true
            player.currentVideoSubTitleIndex = -1
            currentSubtitleIndex = -1
            didApplySavedSubtitlePreference = true
            // TEMPORARY diagnostic — remove once ratio/subtitle memory is verified on device.
            print("[VLC_PREF] subtitle restored: sidecar")
            updateCurrentCue()

        case .embedded(let name, let fallbackIndex):
            guard let track = subtitleTracks.first(where: { $0.name == name })
                    ?? subtitleTracks.first(where: { $0.index == fallbackIndex }) else { return }
            sidecarEnabled = false
            player.currentVideoSubTitleIndex = track.index
            currentSubtitleIndex = track.index
            // VLC can drop an SPU set issued while the stream is still opening.
            // Only latch once the player confirms; until then this re-runs on
            // every time-changed tick, so the restore retries instead of
            // silently failing forever.
            if player.currentVideoSubTitleIndex == track.index {
                didApplySavedSubtitlePreference = true
                // TEMPORARY diagnostic — remove once ratio/subtitle memory is verified on device.
                print("[VLC_PREF] subtitle restored: embedded name=\(track.name) index=\(track.index)")
            }
            updateCurrentCue()

        case .off:
            sidecarEnabled = false
            player.currentVideoSubTitleIndex = -1
            currentSubtitleIndex = -1
            didApplySavedSubtitlePreference = true
            // TEMPORARY diagnostic — remove once ratio/subtitle memory is verified on device.
            print("[VLC_PREF] subtitle restored: off")
            updateCurrentCue()
        }
    }

    // MARK: Audio tracks

    /// Read current VLC audio tracks. VLC exposes parallel arrays with real
    /// track indexes and names once media parses.
    private func refreshAudioTracks() {
        let indexes = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let names = player.audioTrackNames.compactMap { $0 as? String }
        guard indexes.count == names.count else { return }

        let tracks = zip(indexes, names)
            .filter { $0.0 >= 0 }
            .map { AudioTrack(index: $0.0, name: $0.1) }

        if tracks.map(\.index) != audioTracks.map(\.index) {
            audioTracks = tracks
        }

        currentAudioTrackIndex = player.currentAudioTrackIndex
    }

    /// Select an audio track by VLC index.
    func selectAudioTrack(index: Int32) {
        player.currentAudioTrackIndex = index
        currentAudioTrackIndex = index
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
        if player.state == .ended, let key = currentResumeKey {
            Self.clearPosition(for: key)
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
        refreshAudioTracks()

        // Advance the sidecar overlay cue to match the current time, if any.
        updateCurrentCue()

        // Time advancing means real playback is underway: clear any stale
        // loading overlay even if no `.playing` state notification arrived.
        if playbackState == .loading && player.isPlaying {
            playbackState = .ready
        }
        persistPositionIfNeeded()
        isPlaying = player.isPlaying
        refreshTimes()
    }

    /// Pull current time, duration, and fractional progress off the player.
    /// `VLCTime.stringValue` already formats as MM:SS (or HH:MM:SS).
    private func refreshTimes() {
        currentTimeText = player.time.stringValue ?? "--:--"

        if let length = player.media?.length, length.intValue > 0 {
            durationText = length.stringValue ?? "--:--"
            // Remaining = duration - elapsed, formatted via VLCTime so it matches
            // the elapsed/duration formatting (MM:SS or HH:MM:SS).
            let remainingMs = max(0, length.intValue - player.time.intValue)
            let remaining = VLCTime(int: remainingMs).stringValue ?? "--:--"
            remainingTimeText = "-\(remaining)"
        } else {
            durationText = "--:--"
            remainingTimeText = "--:--"
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
    let resumeKey: String
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
        controller.start(url: url, resumeKey: resumeKey)

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
