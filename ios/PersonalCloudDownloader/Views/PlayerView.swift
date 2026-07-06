import SwiftUI
import AVKit
import Combine
import UIKit
import MediaPlayer
import MobileVLCKit

/// Phase 3, step 5: dual-engine playback.
///
/// Chooses the engine by format:
///   - mp4/mov/m4v → native AVPlayer (`VideoPlayer`)
///   - mkv/avi/webm → MobileVLCKit (`VLCPlayerView`)
///   - nil streamURL → error state
/// All engines source from `CompletedFile.streamURL` over Tailscale.
struct PlayerView: View {
    let video: CompletedFile

    /// When true, the player opens straight into fullscreen (the inline player
    /// screen is skipped for normal playback): on appear it enters the existing
    /// fullscreen presentation, and the fullscreen close pops this whole screen
    /// off the nav stack back to the Videos list instead of dropping to inline.
    /// Default false so any inline-first call site keeps its old behavior.
    var startsFullscreen = false

    /// Pops this screen when running in `startsFullscreen` mode — close returns
    /// to the Videos list rather than the (unused) inline player underneath.
    @Environment(\.dismiss) private var dismiss

    /// Guards the one-shot auto-enter so returning from the cover (which lowers
    /// `isFullscreen`, then pops via `onDismiss`) doesn't immediately re-enter.
    @State private var didAutoEnterFullscreen = false

    @State private var player: AVPlayer?
    @StateObject private var vlc = VLCPlayerController()

    /// AVPlayer playback lifecycle, mirrored from the player item's status,
    /// the end-of-playback notification, and the play/pause control status.
    /// Parallels the VLC overlay states; `VideoPlayer` keeps its own controls.
    private enum AVState {
        case loading
        case ready
        case failed
        case ended
    }

    @State private var avState: AVState = .loading

    /// Drives the `fullScreenCover` for whichever engine is active. The same
    /// `player` / `vlc` instances are reused, so playback continues seamlessly
    /// across the inline ⇄ fullscreen transition (no reload, no seek reset).
    @State private var isFullscreen = false

    /// Interface orientation captured the moment fullscreen is entered, so it can
    /// be restored on exit (usually portrait). Default portrait until set.
    @State private var orientationBeforeFullscreen: UIInterfaceOrientation = .portrait

    /// Layout scale shared across the player screen so spacing stays consistent
    /// instead of scattering magic numbers. Pure presentation — no behavior.
    private enum Layout {
        /// Gap between the major stacked blocks (surface, controls, title).
        static let sectionSpacing: CGFloat = 20
        /// Gap inside a tight group (title + caption, slider + times).
        static let groupSpacing: CGFloat = 6
        /// Screen edge inset for inline content.
        static let screenPadding: CGFloat = 16
        /// Corner radius for the inline player surface.
        static let surfaceRadius: CGFloat = 14
    }

    var body: some View {
        Group {
            if let streamURL = video.streamURL {
                if video.isAVPlayerSupported {
                    avPlayback(streamURL)
                } else {
                    vlcPlayback(streamURL)
                }
            } else {
                errorState
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        // Direct-fullscreen open: enter the existing fullscreen presentation as
        // soon as the screen appears, once. The inline surface stays dormant
        // underneath (VLC via `inlineVLCLive`, which is always false in this mode;
        // AVPlayer reuses the same instance, so nothing competes for audio).
        .onAppear {
            guard startsFullscreen, !didAutoEnterFullscreen else { return }
            didAutoEnterFullscreen = true
            enterFullscreen()
        }
        .onDisappear {
            player?.pause()
            vlc.stop()
        }
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: {
            // Both engines rotated to real landscape on entry, so both restore
            // portrait on the way out.
            OrientationHelper.restore(orientationBeforeFullscreen)
            // Direct-open mode: the cover has finished dismissing and orientation
            // is restored, so now pop back to the Videos list. Popping here
            // (rather than at the close tap) avoids tearing the cover down
            // mid-transition.
            if startsFullscreen {
                dismiss()
            }
        }) {
            if let streamURL = video.streamURL {
                fullscreenContent(streamURL)
                    // Real device landscape for BOTH engines. The geometry
                    // request works even with the iPhone rotation lock ON, which
                    // is why the old fake 90° rotated layout is no longer needed.
                    .onAppear {
                        OrientationHelper.lockLandscape()
                    }
            }
        }
    }

    // MARK: Fullscreen

    /// Full-bleed black presentation reusing the same engine surfaces as the
    /// inline view. A tap-target close button sits top-left; the fullscreen
    /// toggle (now a "minimize" affordance) stays in its usual spot.
    private func fullscreenContent(_ streamURL: URL) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if video.isAVPlayerSupported {
                // AVPlayer keeps its framed 16:9 surface, just centered + padded.
                avSurface
                    .padding()

                // AVPlayer fullscreen keeps its always-visible close button;
                // VLC manages its own (auto-hiding with its controls).
                Button {
                    isFullscreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.4))
                }
                .padding()
            } else {
                // Fullscreen VLC runs on its OWN controller (see
                // `VLCFullscreenView`), not the inline `vlc`. The two never play
                // at once: the inline player was torn down before this appeared,
                // and this one tears down on dismiss, after which the inline
                // player resumes. Position carries over via the shared stable-key
                // `savedPositions` store. The close button lives inside it so it
                // auto-hides with the controls.
                //
                // REAL landscape: the cover's `onAppear` requests a device
                // rotation (works even with the rotation lock ON), so this view
                // is laid out directly in the rotated screen's coordinates — no
                // width/height swap, no 90° `rotationEffect`, no safe-inset
                // remap. `geo.size` tracks the rotation, so the layout settles
                // into the true landscape frame once the rotation completes.
                GeometryReader { geo in
                    VLCFullscreenView(
                        streamURL: streamURL,
                        resumeKey: video.path,
                        title: video.displayName,
                        landscapeSize: geo.size,
                        safeInsets: geo.safeAreaInsets,
                        onClose: { isFullscreen = false }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .ignoresSafeArea()
            }
        }
    }

    /// Enter the fullscreen presentation. Shared by the inline enter-fullscreen
    /// button and the direct-open auto-enter. For VLC, tear the inline player
    /// down first (persists position, stops audio, frees the drawable) so the
    /// fullscreen surface — a SEPARATE VLC controller — starts clean with no
    /// second player still holding audio.
    private func enterFullscreen() {
        // Capture orientation before rotating so exit can restore it.
        orientationBeforeFullscreen = OrientationHelper.currentOrientation()
        if video.isAVPlayerSupported {
            // In direct-open the inline `avPlayback.onAppear` (which lazily
            // builds the player) may not have run before the cover presents, so
            // make sure the AVPlayer exists for the fullscreen `avSurface`.
            if player == nil, let url = video.streamURL {
                player = AVPlayer(url: url)
            }
        } else {
            vlc.teardown()
        }
        isFullscreen = true
    }

    /// Top-trailing button overlaid on a player surface to enter fullscreen.
    private var fullscreenButton: some View {
        Button {
            enterFullscreen()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .padding(12)
    }

    // MARK: Shared layout

    /// Inline surface framing: rounded corners + hairline border. Skipped in
    /// fullscreen, where the surface is full-bleed and square. Presentation
    /// only — does not touch the underlying player view.
    @ViewBuilder
    private func framedSurface(_ surface: some View) -> some View {
        if isFullscreen {
            surface
        } else {
            surface
                .clipShape(RoundedRectangle(cornerRadius: Layout.surfaceRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Layout.surfaceRadius, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    /// Title + resolved-URL caption, grouped tightly and centered. Shared by
    /// the AVPlayer and VLC inline layouts.
    private func titleBlock(_ streamURL: URL) -> some View {
        VStack(spacing: Layout.groupSpacing) {
            Text(video.displayName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            urlCaption(streamURL)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: AVPlayer

    /// Shared AVPlayer rendering surface (16:9) with state overlay and the
    /// enter-fullscreen button. Reused by inline and fullscreen presentations.
    private var avSurface: some View {
        framedSurface(
            VideoPlayer(player: player)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { avStateOverlay }
                .overlay(alignment: .topTrailing) {
                    if !isFullscreen { fullscreenButton }
                }
        )
    }

    private func avPlayback(_ streamURL: URL) -> some View {
        VStack(spacing: Layout.sectionSpacing) {
            avSurface

            titleBlock(streamURL)

            Spacer()
        }
        .padding(Layout.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if player == nil {
                player = AVPlayer(url: streamURL)
            }
        }
        // currentItem.status: .readyToPlay → ready, .failed → failed.
        .onReceive(itemStatusPublisher) { status in
            switch status {
            case .readyToPlay:
                if avState == .loading { avState = .ready }
            case .failed:
                avState = .failed
            default:
                break
            }
        }
        // Fired once when playback reaches the end of the item.
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime)
        ) { note in
            if let item = note.object as? AVPlayerItem,
               item === player?.currentItem {
                avState = .ended
            }
        }
        // Auto-dismiss the ended/failed overlay when the user resumes via the
        // system controls (rate > 0 ⇒ actively playing).
        .onReceive(ratePublisher) { rate in
            if rate > 0, avState == .ended || avState == .failed {
                avState = .ready
            }
        }
    }

    /// Publishes the current item's status, re-subscribing whenever the
    /// player or its item changes. Emits nothing until a player exists.
    private var itemStatusPublisher: AnyPublisher<AVPlayerItem.Status, Never> {
        guard let item = player?.currentItem else {
            return Empty().eraseToAnyPublisher()
        }
        return item.publisher(for: \.status).eraseToAnyPublisher()
    }

    /// Publishes the player's playback rate (0 = paused, >0 = playing).
    private var ratePublisher: AnyPublisher<Float, Never> {
        guard let player else {
            return Empty().eraseToAnyPublisher()
        }
        return player.publisher(for: \.rate).eraseToAnyPublisher()
    }

    /// State overlay drawn on top of the AVPlayer surface. Transparent while
    /// playing so `VideoPlayer`'s own controls stay usable; spinner on load,
    /// error message on failure, replay prompt at end-of-playback.
    @ViewBuilder
    private var avStateOverlay: some View {
        switch avState {
        case .loading:
            loadingOverlay("Loading…")
        case .failed:
            failedOverlay(action: replayAV)
        case .ended:
            endedOverlay(action: replayAV)
        case .ready:
            EmptyView()
        }
    }

    // MARK: Shared overlays

    /// Dimmed spinner shown while a surface is buffering / loading.
    private func loadingOverlay(_ label: String) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
    }

    /// Failure state: icon, message, and a Retry button on a rounded card over
    /// a dimmed backdrop. `action` retries playback for the active engine.
    private func failedOverlay(action: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 38))
                    .foregroundStyle(.orange)
                    .frame(width: 64, height: 64)
                    .background(.orange.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(.orange.opacity(0.28), lineWidth: 1))
                Text("Playback failed")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Could not load this video. Check the connection and try again.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button(action: action) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
            .padding(24)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .padding(24)
        }
    }

    /// End-of-playback state: a large Replay affordance over a dimmed backdrop.
    private func endedOverlay(action: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.7)
            Button(action: action) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 52))
                    Text("Replay")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(PlayerPressStyle())
        }
    }

    /// Seek to the start and resume. Used by the AVPlayer replay/retry buttons.
    private func replayAV() {
        avState = .ready
        player?.seek(to: .zero)
        player?.play()
    }

    // MARK: VLC

    /// VLC rendering surface (16:9) with state overlay and the enter-fullscreen
    /// button. Only ONE live `VLCPlayerView` may exist at a time because the
    /// inline and fullscreen presentations share a single `VLCMediaPlayer` (one
    /// drawable). `liveVideo` says whether THIS call site should mount the real
    /// player view or a black placeholder:
    ///   - inline: live only while NOT fullscreen
    ///   - fullscreen: always live (only built while the cover is presented)
    /// Swapping the dormant surface to a placeholder unmounts its VLCPlayerView,
    /// which detaches the drawable, so the active surface claims it cleanly on
    /// every open/close.
    private func vlcSurface(_ streamURL: URL, liveVideo: Bool) -> some View {
        framedSurface(
            Group {
                if liveVideo {
                    VLCPlayerView(url: streamURL, resumeKey: video.path, controller: vlc)
                } else {
                    // Dormant surface: black fill, no VLCPlayerView competing
                    // for the shared drawable.
                    Color.black
                }
            }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
                .overlay { vlcStateOverlay }
                // Sidecar `.srt` overlay: SwiftUI-drawn, so it stays
                // bottom-centered regardless of VLC Fit/Cover (Cover crop would
                // shift native VLC subtitles). Only shows when a sidecar exists.
                .overlay(alignment: .bottom) { SubtitleOverlay(text: vlc.currentSubtitleText) }
                .overlay(alignment: .topTrailing) {
                    if !isFullscreen { fullscreenButton }
                }
        )
    }

    /// Shared VLC control row + scrub slider + time labels. Reused by inline
    /// and fullscreen presentations so play/pause, seek, and ±10s behave the
    /// same in both. `streamURL` is unused here but kept for call-site symmetry.
    private func vlcControls(_ streamURL: URL) -> some View {
        VStack(spacing: Layout.groupSpacing) {
            Slider(
                value: $vlc.progress,
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        vlc.beginScrubbing()
                    } else {
                        vlc.endScrubbing(to: vlc.progress)
                    }
                }
            )

            HStack {
                Text(vlc.currentTimeText)
                Spacer()
                Text(vlc.durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 40) {
                transportButton(systemName: "gobackward.10", font: .title2) {
                    vlc.skipBackward()
                }

                transportButton(
                    systemName: vlc.isPlaying ? "pause.fill" : "play.fill",
                    font: .system(size: 44)
                ) {
                    vlc.togglePlayPause()
                }

                transportButton(systemName: "goforward.10", font: .title2) {
                    vlc.skipForward()
                }
            }
            .foregroundStyle(.tint)
            .padding(.top, Layout.groupSpacing)
        }
    }

    /// One transport control with a generous, consistent tap target.
    private func transportButton(
        systemName: String,
        font: Font,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(font)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
    }

    /// Whether the inline VLC surface should mount a live player. In direct-open
    /// mode the inline player is never used (open → fullscreen, close → pop), so
    /// it stays dormant throughout — this avoids a brief inline start/audio blip
    /// both before the auto-enter (first layout → `onAppear`) and after close
    /// (cover lowered → nav pop). Otherwise: live whenever not fullscreen.
    private var inlineVLCLive: Bool {
        if startsFullscreen { return false }
        return !isFullscreen
    }

    private func vlcPlayback(_ streamURL: URL) -> some View {
        VStack(spacing: Layout.sectionSpacing) {
            vlcSurface(streamURL, liveVideo: inlineVLCLive)

            vlcControls(streamURL)

            titleBlock(streamURL)

            Spacer()
        }
        .padding(Layout.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// State overlay drawn on top of the VLC video surface. Transparent
    /// when playing (`.ready`) so frames show through; otherwise a spinner,
    /// error message, or replay prompt over a dimmed backdrop.
    @ViewBuilder
    private var vlcStateOverlay: some View {
        switch vlc.playbackState {
        case .loading:
            loadingOverlay("Buffering…")
        case .failed:
            failedOverlay(action: vlc.replay)
        case .ended:
            endedOverlay(action: vlc.replay)
        case .ready:
            EmptyView()
        }
    }

    /// Small, non-distracting resolved URL for debugging.
    private func urlCaption(_ streamURL: URL) -> some View {
        Text(streamURL.absoluteString)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .padding(.horizontal, Layout.screenPadding)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 76, height: 76)
                .background(.orange.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(.orange.opacity(0.30), lineWidth: 1))

            Text(video.displayName)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text("No valid stream URL for this video.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.70))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .padding(Layout.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.94))
    }
}

/// Standalone fullscreen VLC surface with its OWN `VLCPlayerController`,
/// independent of the inline player. The inline player is torn down before this
/// appears and resumes after it's gone, so only one VLC player ever holds audio.
/// Playback position carries across via the shared stable-key `savedPositions`
/// store: this view's controller resumes from where inline left off, and on
/// dismiss it persists its own position for inline to pick back up.
///
/// Self-contained controls (scrub slider, time labels, ±10s, play/pause) bound
/// to its own controller — it does not touch `PlayerView`'s inline `vlc`.
private struct VLCFullscreenView: View {
    @Environment(\.scenePhase) private var scenePhase

    let streamURL: URL
    let resumeKey: String
    /// Clean video title shown centered in the top bar (e.g. the filename).
    let title: String
    /// The real landscape screen size this whole view is laid out in (the device
    /// is rotated to true landscape while fullscreen). Video + chrome share this
    /// frame; it also doubles as the VLC Fill/Cover drawable surface.
    let landscapeSize: CGSize
    /// The screen's real landscape safe-area insets, so the chrome keeps the
    /// close button and transport clear of the notch / Dynamic Island / home
    /// indicator.
    let safeInsets: EdgeInsets
    /// Dismiss the fullscreen cover. Owned by `PlayerView`; the close button
    /// lives here so it fades in/out with the rest of the controls.
    let onClose: () -> Void

    @StateObject private var fsVlc = VLCPlayerController()

    /// Whether the controls (transport + close) are currently shown. Tapping the
    /// video toggles this; an auto-hide timer clears it while playing.
    @State private var controlsVisible = true

    /// Pending auto-hide work, cancelled/rescheduled on every show or tap so the
    /// controls stay up for the full delay after the latest interaction.
    @State private var autoHideTask: DispatchWorkItem?
    @State private var wallClockText = Self.wallClockFormatter.string(from: Date())
    @State private var videoGestureMode: VideoGestureMode = .undecided
    @State private var gestureStartBrightness: CGFloat = UIScreen.main.brightness
    @State private var gestureStartVolume: Float = SystemVolumeController.shared.volume
    @State private var adjustmentOverlay: AdjustmentOverlay?
    @State private var adjustmentOverlayHideTask: DispatchWorkItem?
    @State private var isSearchingSubtitles = false
    @State private var subtitleSearchMessage: String?

    /// Lock mode: hides all chrome and swallows gestures so nothing can seek,
    /// pause, or adjust by accident. Only the small unlock control responds.
    @State private var isLocked = false

    /// Whether the unlock control is currently shown while locked. Tapping the
    /// video toggles it; it auto-hides like the normal controls.
    @State private var unlockControlVisible = true
    @State private var unlockHideTask: DispatchWorkItem?

    /// Which ±10s transport button is currently flashing tap feedback, if any.
    /// Set on tap, cleared shortly after — display only, independent of the
    /// seek (which VLC performs immediately).
    @State private var skipFlash: SkipDirection?

    private enum SkipDirection {
        case backward
        case forward
    }

    /// Battery snapshot for the top bar indicator. -1 / .unknown until
    /// monitoring is enabled in `onAppear`; the indicator hides itself then.
    @State private var batteryLevel: Float = UIDevice.current.batteryLevel
    @State private var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState

    /// Seconds the controls stay visible before auto-hiding during playback.
    private let autoHideDelay: TimeInterval = 3
    private let adjustmentOverlayHideDelay: TimeInterval = 0.8
    private let savedBrightnessKey = "vlcFullscreenLastBrightness"
    private let savedVolumeKey = "vlcFullscreenLastVolume"
    private let wallClockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let wallClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private enum VideoGestureMode {
        case undecided
        case horizontal
        case brightness
        case volume
    }

    private struct AdjustmentOverlay {
        let kind: Kind
        let value: Double

        enum Kind {
            case brightness
            case volume

            var icon: String {
                switch self {
                case .brightness:
                    return "sun.max.fill"
                case .volume:
                    return "speaker.wave.2.fill"
                }
            }

            var label: String {
                switch self {
                case .brightness:
                    return "Brightness"
                case .volume:
                    return "Volume"
                }
            }
        }
    }


    var body: some View {
        // Laid out directly in the REAL landscape screen frame (`landscapeSize`);
        // the device itself is rotated while fullscreen, so video + chrome share
        // one ordinary coordinate space — no rotation transforms anywhere. The
        // native status bar is hidden the whole time (see `.statusBarHidden`), so
        // the top bar carries its own clock.
        ZStack {
            // Video fills the landscape frame; VLC preserves aspect internally
            // and letterboxes against the black backdrop.
            VLCPlayerView(url: streamURL, resumeKey: resumeKey, controller: fsVlc)
                .frame(width: landscapeSize.width, height: landscapeSize.height)

            // Full-area tap/swipe target. Above the video, below the bars/buttons
            // so direct drags on the top timeline still go to the timeline.
            Color.clear
                .contentShape(Rectangle())
                .gesture(videoAreaGesture)

            SystemVolumeView()
                .frame(width: 120, height: 32)
                .opacity(0.001)
                .allowsHitTesting(false)
                // Hidden volume plumbing only — must never be a VoiceOver
                // element, or its slider gets focused and spoken mid-playback.
                .accessibilityHidden(true)

            // State overlay (spinner / replay) centered over the video.
            overlay

            adjustmentOverlayView

            VStack {
                Spacer()
                SubtitleOverlay(text: fsVlc.currentSubtitleText)
                    .padding(.bottom, max(12, safeInsets.bottom + 4))
            }

            if controlsVisible && !isLocked {
                // nPlayer-style chrome: a translucent top bar (close, times,
                // title, subtitle menu, timeline) across the top, and a
                // translucent bottom bar (transport) across the bottom, with a floating
                // Fit/Cover pill. All fade together with the controls.
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
                .transition(.opacity)
            }

            // Locked: the ONLY interactive element is this small unlock control,
            // in the same circle style as the other overlay buttons. Any locked
            // touch reveals it; it auto-hides like the normal controls.
            if isLocked && unlockControlVisible {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack {
                        Button(action: unlockControls) {
                            Image(systemName: "lock.open.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(.black.opacity(0.45), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(PlayerPressStyle())
                        Spacer()
                    }
                    .padding(.leading, 16 + safeInsets.leading)
                    .padding(.trailing, 16 + safeInsets.trailing)
                    .padding(.bottom, 8 + safeInsets.bottom)
                }
                .transition(.opacity)
            }
        }
        .frame(width: landscapeSize.width, height: landscapeSize.height)
        .background(Color.black)
        // Native iOS status bar stays hidden the WHOLE time in fullscreen, so it
        // never overlaps the video or the close button. The top bar carries its
        // own live clock instead.
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear {
            wallClockText = Self.wallClockFormatter.string(from: Date())
            // Battery monitoring only while the fullscreen player is up
            // (disabled again in onDisappear).
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
            batteryState = UIDevice.current.batteryState
            restoreSavedAdjustments()
            scheduleAutoHide()
            // Give the controller its surface size up front so a RESTORED
            // Fit/Cover preference is applied to the actual rendering —
            // previously only the ratio button ever provided it.
            fsVlc.updateAspectDrawableSize(landscapeSize)
        }
        // The cover can appear before the device finishes rotating to real
        // landscape; re-record the settled size so a restored Cover crops to
        // the true landscape aspect, not the pre-rotation frame.
        .onChange(of: landscapeSize) { size in
            fsVlc.updateAspectDrawableSize(size)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                syncAdjustmentState()
            }
        }
        .onReceive(wallClockTimer) { date in
            wallClockText = Self.wallClockFormatter.string(from: date)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryLevelDidChangeNotification)
        ) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.batteryStateDidChangeNotification)
        ) { _ in
            batteryState = UIDevice.current.batteryState
        }
        .alert("Subtitles", isPresented: Binding(
            get: { subtitleSearchMessage != nil },
            set: { if !$0 { subtitleSearchMessage = nil } }
        )) {
            Button("OK", role: .cancel) { subtitleSearchMessage = nil }
        } message: {
            Text(subtitleSearchMessage ?? "")
        }
        // The controller's media frees with the view; `teardown` also persists
        // position and stops audio so inline can resume cleanly.
        .onDisappear {
            autoHideTask?.cancel()
            adjustmentOverlayHideTask?.cancel()
            unlockHideTask?.cancel()
            UIDevice.current.isBatteryMonitoringEnabled = false
            fsVlc.teardown()
        }
    }

    /// Close fullscreen. Persists the CURRENT fullscreen playhead synchronously
    /// FIRST, then dismisses. Order matters: dismissing the cover makes SwiftUI
    /// remount the inline surface, whose `start` reads `savedPositions` to
    /// resume. That remount runs before this view's `onDisappear` (and its
    /// `teardown`), so if the position were only persisted there, inline would
    /// resume from the stale pre-fullscreen position. Persisting here closes that
    /// race; the later `teardown` persist is then a harmless idempotent re-save.
    private func closeFullscreen() {
        fsVlc.persistPosition()
        onClose()
    }


    /// Toggle control visibility on a video tap. Showing (re)arms the auto-hide
    /// timer; hiding cancels it.
    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible {
            scheduleAutoHide()
        } else {
            autoHideTask?.cancel()
        }
    }

    // MARK: Lock

    /// Enter lock mode: chrome down, gestures swallowed, only the small unlock
    /// control (auto-hiding like the normal controls) stays interactive.
    private func lockControls() {
        isLocked = true
        controlsVisible = false
        autoHideTask?.cancel()
        unlockControlVisible = true
        scheduleUnlockHide()
    }

    /// Exit lock mode and restore the normal controls exactly as before.
    private func unlockControls() {
        isLocked = false
        unlockHideTask?.cancel()
        controlsVisible = true
        scheduleAutoHide()
    }

    /// Any touch while locked REVEALS the unlock control and re-arms its
    /// auto-hide. Deliberately not a toggle: a toggle could hide it on the very
    /// tap meant to reach it, and a slightly-moved tap did nothing — either way
    /// the user raced the auto-hide timer with no reliable way out.
    private func revealUnlockControl() {
        unlockControlVisible = true
        scheduleUnlockHide()
    }

    /// Auto-hide the unlock control while playing, same delay/behavior as the
    /// normal controls' `scheduleAutoHide`.
    private func scheduleUnlockHide() {
        unlockHideTask?.cancel()
        let task = DispatchWorkItem {
            if fsVlc.isPlaying {
                unlockControlVisible = false
            }
        }
        unlockHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: task)
    }

    private var videoAreaGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isLocked else {
                    revealUnlockControl()
                    return
                }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let isHorizontalSwipe = abs(horizontal) >= 44 && abs(horizontal) > abs(vertical) * 1.5
                let isVerticalSwipe = abs(vertical) >= 44 && abs(vertical) > abs(horizontal) * 1.5

                if videoGestureMode == .undecided {
                    if isHorizontalSwipe {
                        videoGestureMode = .horizontal
                    } else if isVerticalSwipe {
                        let mode: VideoGestureMode = value.startLocation.x < landscapeSize.width / 2 ? .brightness : .volume
                        videoGestureMode = mode
                        gestureStartBrightness = UIScreen.main.brightness
                        gestureStartVolume = SystemVolumeController.shared.volume
                        updateVerticalAdjustment(mode: mode, translationY: vertical)
                    }
                } else if videoGestureMode == .brightness || videoGestureMode == .volume {
                    updateVerticalAdjustment(mode: videoGestureMode, translationY: vertical)
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let isHorizontalSwipe = abs(horizontal) >= 44 && abs(horizontal) > abs(vertical) * 1.5
                let isTap = hypot(horizontal, vertical) < 12

                // Locked: swipes (seek/brightness/volume) are swallowed; ANY
                // touch — tap or swipe — reveals the unlock control so the
                // user is never trapped.
                if isLocked {
                    revealUnlockControl()
                    videoGestureMode = .undecided
                    return
                }

                if videoGestureMode == .horizontal || isHorizontalSwipe {
                    if horizontal > 0 {
                        fsVlc.skipForward()
                    } else {
                        fsVlc.skipBackward()
                    }
                } else if isTap {
                    toggleControls()
                } else if videoGestureMode == .brightness || videoGestureMode == .volume {
                    scheduleAdjustmentOverlayHide()
                }
                videoGestureMode = .undecided
            }
    }

    private func updateVerticalAdjustment(mode: VideoGestureMode, translationY: CGFloat) {
        let delta = Float(-translationY / max(landscapeSize.height, 1)) * 1.2
        switch mode {
        case .brightness:
            let value = clamp(Double(gestureStartBrightness) + Double(delta))
            UIScreen.main.brightness = CGFloat(value)
            UserDefaults.standard.set(value, forKey: savedBrightnessKey)
            showAdjustmentOverlay(kind: .brightness, value: value)
        case .volume:
            let value = clamp(Double(gestureStartVolume) + Double(delta))
            let appliedValue = SystemVolumeController.shared.setVolume(Float(value))
            UserDefaults.standard.set(appliedValue, forKey: savedVolumeKey)
            showAdjustmentOverlay(kind: .volume, value: Double(appliedValue))
        case .undecided, .horizontal:
            break
        }
    }

    private func restoreSavedAdjustments() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedBrightnessKey) != nil {
            UIScreen.main.brightness = CGFloat(clamp(defaults.double(forKey: savedBrightnessKey)))
        }

        if defaults.object(forKey: savedVolumeKey) != nil {
            let savedVolume = Float(clamp(defaults.double(forKey: savedVolumeKey)))
            applySavedVolumeIfNeeded(savedVolume)
        }

        syncAdjustmentState()
        DispatchQueue.main.async {
            if defaults.object(forKey: savedVolumeKey) != nil {
                let savedVolume = Float(clamp(defaults.double(forKey: savedVolumeKey)))
                applySavedVolumeIfNeeded(savedVolume)
            }
            syncAdjustmentState()
        }
    }

    /// Only touch the system volume when the saved value actually differs from
    /// the current one. A redundant set fires the MPVolumeView slider's
    /// `.valueChanged` action, which can surface a system/VoiceOver volume
    /// announcement on every fullscreen open for no user-visible change.
    private func applySavedVolumeIfNeeded(_ savedVolume: Float) {
        guard abs(savedVolume - SystemVolumeController.shared.volume) > 0.01 else { return }
        _ = SystemVolumeController.shared.setVolume(savedVolume)
    }

    private func syncAdjustmentState() {
        gestureStartBrightness = UIScreen.main.brightness
        gestureStartVolume = SystemVolumeController.shared.volume
        if let overlay = adjustmentOverlay {
            switch overlay.kind {
            case .brightness:
                adjustmentOverlay = AdjustmentOverlay(kind: .brightness, value: Double(UIScreen.main.brightness))
            case .volume:
                adjustmentOverlay = AdjustmentOverlay(kind: .volume, value: Double(SystemVolumeController.shared.volume))
            }
        }
    }

    private func showAdjustmentOverlay(kind: AdjustmentOverlay.Kind, value: Double) {
        adjustmentOverlayHideTask?.cancel()
        adjustmentOverlay = AdjustmentOverlay(kind: kind, value: value)
    }

    private func scheduleAdjustmentOverlayHide() {
        adjustmentOverlayHideTask?.cancel()
        let task = DispatchWorkItem {
            adjustmentOverlay = nil
        }
        adjustmentOverlayHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + adjustmentOverlayHideDelay, execute: task)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Hide the controls after `autoHideDelay`, but only while playing — paused
    /// playback keeps them up so the user isn't left with a frozen, bare frame.
    /// Re-arming cancels any previously scheduled hide.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        let task = DispatchWorkItem {
            if fsVlc.isPlaying {
                controlsVisible = false
            }
        }
        autoHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: task)
    }

    @ViewBuilder
    private var overlay: some View {
        switch fsVlc.playbackState {
        case .loading:
            ZStack {
                Color.black.opacity(0.35)
                ProgressView().tint(.white).scaleEffect(1.4)
            }
        case .failed, .ended:
            ZStack {
                Color.black.opacity(0.7)
                Button {
                    fsVlc.replay()
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 52))
                        Text("Replay").font(.headline)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(PlayerPressStyle())
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var adjustmentOverlayView: some View {
        if let adjustmentOverlay {
            VStack(spacing: 10) {
                Image(systemName: adjustmentOverlay.kind.icon)
                    .font(.title3.weight(.semibold))
                Text(adjustmentOverlay.kind.label)
                    .font(.caption.weight(.semibold))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * CGFloat(adjustmentOverlay.value))
                    }
                }
                .frame(height: 3)
                Text("\(Int(round(adjustmentOverlay.value * 100)))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 132)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// While dragging the timeline, the top-bar time labels track the SCRUB
    /// TARGET (drag `progress` × duration) instead of the frozen live playhead
    /// (`refreshTimes` keeps publishing the real clock during a drag). Formatted
    /// via `VLCTime` so it matches the live labels exactly. Falls back to the
    /// live text when the duration isn't known yet. Display only — the seek
    /// still happens on release via `endScrubbing`.
    private var scrubTimeLabels: (current: String, remaining: String)? {
        guard let lengthMs = fsVlc.player.media?.length.intValue, lengthMs > 0 else { return nil }
        let targetMs = Int32((Double(lengthMs) * min(max(fsVlc.progress, 0), 1)).rounded())
        let current = VLCTime(int: targetMs).stringValue ?? "--:--"
        let remaining = VLCTime(int: max(0, lengthMs - targetMs)).stringValue ?? "--:--"
        return (current, "-\(remaining)")
    }

    private var displayedCurrentTimeText: String {
        guard fsVlc.isScrubbing, let labels = scrubTimeLabels else { return fsVlc.currentTimeText }
        return labels.current
    }

    private var displayedRemainingTimeText: String {
        guard fsVlc.isScrubbing, let labels = scrubTimeLabels else { return fsVlc.remainingTimeText }
        return labels.remaining
    }

    /// nPlayer-style top bar: centered wall clock above close + timeline-backed elapsed • title • remaining.
    /// Flat, with a light top-down scrim for legibility (no material) so it reads
    /// over any frame without heavy chrome. The native iOS status bar is hidden,
    /// and the wall clock/playback times live here.
    private var topBar: some View {
        VStack(spacing: 2) {
            Text(wallClockText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .center)
                // Battery sits at the trailing edge of the clock row; the clock
                // itself stays centered above the timeline. The extra inset keeps
                // the capsule clear of the display's rounded corner: in landscape
                // the trailing safe inset can be 0 (notch on the other side), and
                // this row is at the very top where the corner curves in.
                .overlay(alignment: .trailing) {
                    BatteryIndicatorView(level: batteryLevel, state: batteryState)
                        .padding(.trailing, max(0, 28 - safeInsets.trailing))
                }

            HStack(spacing: 0) {
                Button(action: closeFullscreen) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlayerPressStyle())

                TimelineSlider(
                    progress: $fsVlc.progress,
                    onScrubBegan: { fsVlc.beginScrubbing() },
                    onScrubEnded: { fraction in
                        fsVlc.endScrubbing(to: fraction)
                        if controlsVisible { scheduleAutoHide() }
                    }
                )
                .overlay {
                    HStack(spacing: 12) {
                        Text(displayedCurrentTimeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.95))

                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity)

                        Text(displayedRemainingTimeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
                }
                .frame(height: 44)
            }
        }
        .padding(.leading, 16 + safeInsets.leading)
        .padding(.trailing, 16 + safeInsets.trailing)
        .padding(.top, 6 + safeInsets.top)
        .padding(.bottom, 0)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Compact nPlayer-style bottom bar: a tight transport row, with the
    /// Fit/Cover pill floating at the trailing edge. Flat scrim (no material),
    /// reduced paddings and icon sizes so it stays low-profile and covers little
    /// video. Playback times and the timeline are in the top bar, so none are
    /// repeated here.
    private var bottomBar: some View {
        HStack(spacing: 40) {
            transportButton(systemName: "gobackward.10", font: .title3) {
                flashSkipButton(.backward)
                fsVlc.skipBackward()
            }
            .background {
                Circle().fill(.white.opacity(skipFlash == .backward ? 0.25 : 0))
            }
            .scaleEffect(skipFlash == .backward ? 1.12 : 1)

            transportButton(
                systemName: fsVlc.isPlaying ? "pause.fill" : "play.fill",
                font: .system(size: 30)
            ) {
                fsVlc.togglePlayPause()
            }

            transportButton(systemName: "goforward.10", font: .title3) {
                flashSkipButton(.forward)
                fsVlc.skipForward()
            }
            .background {
                Circle().fill(.white.opacity(skipFlash == .forward ? 0.25 : 0))
            }
            .scaleEffect(skipFlash == .forward ? 1.12 : 1)
        }
        .animation(.easeOut(duration: 0.18), value: skipFlash)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            HStack(spacing: 8) {
                lockButton
                subtitleButton
                if fsVlc.hasSelectableAudioTracks {
                    audioButton
                }
            }
        }
        .overlay(alignment: .trailing) { ratioButton }
        // Horizontal backdrop behind the whole controls row (lock, subtitle,
        // transport, audio, Fit/Cover), in the chrome's existing translucent
        // style. Fades in/out with the row; the timeline stays in the top bar.
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(.leading, 16 + safeInsets.leading)
        .padding(.trailing, 16 + safeInsets.trailing)
        .padding(.top, 6)
        .padding(.bottom, 8 + safeInsets.bottom)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Brief tap-feedback flash on a ±10s button: a soft white circle + slight
    /// scale-up that fades right back out, so a registered tap is visible even
    /// though the seek itself is instant. The guard keeps a pending clear from
    /// wiping the OTHER button's flash when the user alternates quickly.
    private func flashSkipButton(_ direction: SkipDirection) {
        skipFlash = direction
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if skipFlash == direction { skipFlash = nil }
        }
    }

    /// Subtitle picker. Re-arms the auto-hide timer so changing the choice
    /// doesn't hide the controls.
    /// Shows every source together: sidecar overlay, embedded VLC tracks, Off,
    /// and provider search.
    @ViewBuilder
    private var subtitleButton: some View {
        Menu {
            if fsVlc.hasSidecarSubtitle {
                Button {
                    fsVlc.setSidecarEnabled(true)
                    if controlsVisible { scheduleAutoHide() }
                } label: {
                    Label("Subtitles", systemImage: fsVlc.sidecarEnabled ? "checkmark" : "")
                }
            }
            ForEach(fsVlc.subtitleTracks) { track in
                Button {
                    fsVlc.setSidecarEnabled(false)
                    fsVlc.selectSubtitle(track: track)
                    if controlsVisible { scheduleAutoHide() }
                } label: {
                    Label(
                        track.name,
                        systemImage: !(fsVlc.hasSidecarSubtitle && fsVlc.sidecarEnabled)
                            && fsVlc.currentSubtitleIndex == track.index ? "checkmark" : ""
                    )
                }
            }
            Button {
                fsVlc.setSidecarEnabled(false)
                fsVlc.selectSubtitle(index: -1)
                if controlsVisible { scheduleAutoHide() }
            } label: {
                Label(
                    "Off",
                    systemImage: !(fsVlc.hasSidecarSubtitle && fsVlc.sidecarEnabled)
                        && fsVlc.currentSubtitleIndex == -1 ? "checkmark" : ""
                )
            }
            Button {
                findSubtitles()
                if controlsVisible { scheduleAutoHide() }
            } label: {
                Label(
                    isSearchingSubtitles
                        ? "Searching..."
                        : (fsVlc.hasSidecarSubtitle ? "Find better subtitles" : "Find subtitles"),
                    systemImage: "magnifyingglass"
                )
            }
            .disabled(isSearchingSubtitles)
        } label: {
            subtitleButtonLabel(
                on: (fsVlc.hasSidecarSubtitle && fsVlc.sidecarEnabled)
                    || fsVlc.currentSubtitleIndex != -1
                    || isSearchingSubtitles
            )
        }
        .padding(.leading, 4)
    }

    private func findSubtitles() {
        guard !isSearchingSubtitles else { return }
        isSearchingSubtitles = true
        fsVlc.searchMissingSubtitle(for: streamURL) { status in
            DispatchQueue.main.async {
                isSearchingSubtitles = false
                if status == "found" || status == "exists" {
                    fsVlc.setSidecarEnabled(true)
                    return
                }
                subtitleSearchMessage = subtitleSearchFailureMessage(for: status)
            }
        }
    }

    private func subtitleSearchFailureMessage(for status: String) -> String {
        switch status {
        case "not_found":
            return "No subtitle found."
        case "low_confidence":
            return "No safe subtitle match found. Existing subtitle was kept."
        case "provider_not_configured":
            return "Subtitle search is not configured on the server."
        case "provider_unavailable":
            return "Subtitle provider is unavailable right now."
        case "download_failed":
            return "Subtitle download failed. Please try again."
        case "invalid_path":
            return "This video path cannot be searched."
        default:
            return "Subtitle search failed."
        }
    }

    /// Shared captions-bubble icon for the subtitle picker; filled when subs are
    /// currently on.
    private func subtitleButtonLabel(on: Bool) -> some View {
        Image(systemName: on ? "captions.bubble.fill" : "captions.bubble")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45), in: Circle())
            .contentShape(Circle())
    }

    /// Lock button, same circle style as the subtitle/audio buttons. Locks the
    /// player against accidental taps/gestures/seeking.
    private var lockButton: some View {
        Button(action: lockControls) {
            Image(systemName: "lock.open")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .padding(.leading, 4)
    }

    /// Audio track picker. Shown only when VLC reports more than one real audio
    /// track, so single-track videos do not show a dead menu.
    private var audioButton: some View {
        Menu {
            ForEach(fsVlc.audioTracks) { track in
                Button {
                    fsVlc.selectAudioTrack(index: track.index)
                    if controlsVisible { scheduleAutoHide() }
                } label: {
                    Label(
                        track.name,
                        systemImage: fsVlc.currentAudioTrackIndex == track.index ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
    }

    /// Cycles Fit → Zoom → 16:9 → 4:3 → 1:1 → Stretch and shows the current
    /// mode. Re-arms the auto-hide timer so adjusting the ratio doesn't
    /// immediately hide controls.
    private var ratioButton: some View {
        Button {
            fsVlc.cycleAspect(drawableSize: landscapeSize)
            if controlsVisible { scheduleAutoHide() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: fsVlc.aspectMode.icon)
                Text(fsVlc.aspectMode.label)
                    .frame(minWidth: 46, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PlayerPressStyle())
        .padding(.trailing, 4)
    }

    /// Compact transport control: a 48×48 tap target (still ≥44pt, comfortable to
    /// hit) without the bulk of the old 56pt frame, keeping the bottom bar slim.
    private func transportButton(
        systemName: String,
        font: Font,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(font)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
    }
}

private struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private final class SystemVolumeController {
    static let shared = SystemVolumeController()

    private var volumeView: MPVolumeView?
    private var slider: UISlider?

    var volume: Float {
        guard Thread.isMainThread else {
            var current = AVAudioSession.sharedInstance().outputVolume
            DispatchQueue.main.sync {
                current = self.volume
            }
            return current
        }

        findSlider()
        let sessionVolume = AVAudioSession.sharedInstance().outputVolume
        guard let slider else { return sessionVolume }
        return abs(slider.value - sessionVolume) < 0.005 ? slider.value : sessionVolume
    }

    func attach(volumeView: MPVolumeView) {
        DispatchQueue.main.async { [weak self] in
            self?.volumeView = volumeView
            self?.findSlider()
        }
    }

    @discardableResult
    func setVolume(_ volume: Float) -> Float {
        let clamped = min(max(volume, 0), 1)

        guard Thread.isMainThread else {
            var applied = clamped
            DispatchQueue.main.sync {
                applied = self.setVolume(clamped)
            }
            return applied
        }

        findSlider()
        guard let slider else {
            return AVAudioSession.sharedInstance().outputVolume
        }

        slider.value = clamped
        slider.sendActions(for: .valueChanged)
        return slider.value
    }

    private func findSlider() {
        guard let volumeView else { return }
        slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 120, height: 32))
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        // Off-screen control used only to drive system volume; hide it (and its
        // UISlider) from the accessibility tree so VoiceOver never announces it.
        view.accessibilityElementsHidden = true
        DispatchQueue.main.async {
            SystemVolumeController.shared.attach(volumeView: view)
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        DispatchQueue.main.async {
            SystemVolumeController.shared.attach(volumeView: uiView)
        }
    }
}

/// nPlayer-style scrub timeline: a full-height dim area with an amber "watched"
/// fill. Replaces the system `Slider` for full control over the filled/unfilled
/// look. Seek behavior is unchanged — it drives the same controller scrub callbacks:
///   - `onScrubBegan` once when a drag starts (freezes live progress updates),
///   - `onScrubEnded(fraction)` when the drag ends (performs the seek).
/// While dragging it updates the bound `progress` so the fill tracks the
/// finger; the controller suppresses its own progress writes during the drag.
private struct TimelineSlider: View {
    @Binding var progress: Double
    let onScrubBegan: () -> Void
    let onScrubEnded: (Double) -> Void

    /// True between drag start and end, so the gesture only fires `onScrubBegan`
    /// once and maps subsequent moves to the live fill.
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(progress, 0), 1)
            let fillWidth = width * CGFloat(clamped)

            ZStack(alignment: .leading) {
                // Unfilled (remaining) track — dim.
                Rectangle()
                    .fill(.black.opacity(0.42))

                // Watched (filled) track.
                Rectangle()
                    .fill(Color(red: 0.86, green: 0.61, blue: 0.18))
                    .frame(width: fillWidth)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle()) // full-height tap/drag target
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onScrubBegan()
                        }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        progress = Double(fraction)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        progress = Double(fraction)
                        dragging = false
                        onScrubEnded(Double(fraction))
                    }
            )
        }
    }
}

/// iOS status-bar-style battery indicator: capsule outline, small cap, inner
/// fill scaled to the charge level, plus a percentage matching the clock's
/// caption styling. Renders nothing when the level/state is unknown (e.g.
/// Simulator, or before monitoring is enabled) so no broken UI shows.
private struct BatteryIndicatorView: View {
    /// 0.0–1.0 from `UIDevice.current.batteryLevel`; -1 when unknown.
    let level: Float
    let state: UIDevice.BatteryState

    var body: some View {
        if state != .unknown, level >= 0 {
            HStack(spacing: 5) {
                Text("\(Int(round(level * 100)))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 1) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .stroke(.white.opacity(0.55), lineWidth: 1)
                            .frame(width: 23, height: 11.5)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fillColor)
                            .frame(width: max(2.5, 19 * CGFloat(min(max(level, 0), 1))), height: 7.5)
                            .padding(.leading, 2)
                    }
                    // The small cap on the battery's right end.
                    RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                        .fill(.white.opacity(0.55))
                        .frame(width: 1.6, height: 4)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Green while charging/full, red when low, white otherwise — the standard
    /// iOS status bar treatment.
    private var fillColor: Color {
        if state == .charging || state == .full { return .green }
        return level <= 0.2 ? .red : .white
    }
}

/// nPlayer/cinema-style subtitle line drawn in SwiftUI: white text, a thin black
/// outline (four offset shadow copies), no background box, centered, compact
/// 1–2 lines. Renders nothing when `text` is nil/empty so no broken UI shows.
/// Used as an overlay on the VLC surface so subtitles stay screen-stable in
/// Cover mode (native VLC subtitles shift with the crop).
private struct SubtitleOverlay: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                // Thin black outline via four 1pt offset shadows — legible over
                // any background without a solid box.
                .shadow(color: .black, radius: 0.5, x: 1, y: 0)
                .shadow(color: .black, radius: 0.5, x: -1, y: 0)
                .shadow(color: .black, radius: 0.5, x: 0, y: 1)
                .shadow(color: .black, radius: 0.5, x: 0, y: -1)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

#Preview {
    NavigationStack {
        PlayerView(
            video: CompletedFile(
                name: "Sample/Big Buck Bunny.mp4",
                path: "/data/Sample/Big Buck Bunny.mp4",
                url: "http://100.95.39.107:8090/files/Sample/Big%20Buck%20Bunny.mp4",
                modifiedAt: nil
            )
        )
    }
}

#Preview("VLC format") {
    NavigationStack {
        PlayerView(
            video: CompletedFile(
                name: "Sample/Movie.mkv",
                path: "/data/Sample/Movie.mkv",
                url: "http://100.95.39.107:8090/files/Sample/Movie.mkv",
                modifiedAt: nil
            )
        )
    }
}

#Preview("Invalid URL") {
    NavigationStack {
        PlayerView(
            video: CompletedFile(
                name: "Sample/Broken.mp4",
                path: "/data/Sample/Broken.mp4",
                url: "/Sample/Broken.mp4",
                modifiedAt: nil
            )
        )
    }
}
