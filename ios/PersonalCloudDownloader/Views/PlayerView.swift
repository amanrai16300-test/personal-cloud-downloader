import SwiftUI
import AVKit
import Combine
import UIKit

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
            // Only AVPlayer asked the system to rotate (real landscape). VLC uses
            // a whole-player fake-landscape rotation that never rotated the
            // device — it works even with the iPhone rotation lock ON — so it has
            // nothing to restore.
            if video.isAVPlayerSupported {
                OrientationHelper.restore(orientationBeforeFullscreen)
            }
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
                    // AVPlayer requests a real device landscape rotation. VLC does
                    // NOT — it presents a rotated (fake-landscape) layout that
                    // works even with the rotation lock on, so it must not request
                    // a device rotation here.
                    .onAppear {
                        if video.isAVPlayerSupported {
                            OrientationHelper.lockLandscape()
                        }
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
                // player resumes. Position carries over via the shared per-URL
                // `savedPositions` store. The close button lives inside it so it
                // auto-hides with the controls.
                //
                // FAKE landscape (reliable with rotation lock ON): the device
                // stays portrait and the user tilts the phone to watch. The WHOLE
                // player — video AND chrome (top bar, clock, title, times, timeline,
                // transport, subtitles, Fit/Cover, close) — is laid out in one
                // landscape-shaped frame (portrait width/height swapped), then
                // rotated 90° and centered to fill the portrait screen. One frame,
                // one rotation, so everything reads horizontally to the tilted user
                // — true landscape look without depending on a device rotation that
                // the rotation lock would block.
                GeometryReader { geo in
                    // Landscape frame = portrait size swapped. Also the VLC
                    // Fill/Cover drawable surface.
                    let landscapeSize = CGSize(width: geo.size.height, height: geo.size.width)
                    VLCFullscreenView(
                        streamURL: streamURL,
                        title: video.displayName,
                        landscapeSize: landscapeSize,
                        // Portrait safe-area insets remapped into the rotated
                        // landscape frame: a 90° rotation sends portrait-top → the
                        // landscape leading edge, portrait-bottom → trailing,
                        // portrait-leading → bottom, portrait-trailing → top.
                        safeInsets: EdgeInsets(
                            top: geo.safeAreaInsets.trailing,
                            leading: geo.safeAreaInsets.top,
                            bottom: geo.safeAreaInsets.leading,
                            trailing: geo.safeAreaInsets.bottom
                        ),
                        onClose: { isFullscreen = false }
                    )
                    .frame(width: landscapeSize.width, height: landscapeSize.height)
                    .rotationEffect(.degrees(90))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
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
                .contentShape(Circle())
        }
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
                Text("Playback failed")
                    .font(.headline)
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
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            .buttonStyle(.plain)
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
                    VLCPlayerView(url: streamURL, controller: vlc)
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
        .buttonStyle(.plain)
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
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text(video.displayName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("No valid stream URL for this video.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Layout.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Standalone fullscreen VLC surface with its OWN `VLCPlayerController`,
/// independent of the inline player. The inline player is torn down before this
/// appears and resumes after it's gone, so only one VLC player ever holds audio.
/// Playback position carries across via the shared per-URL `savedPositions`
/// store: this view's controller resumes from where inline left off, and on
/// dismiss it persists its own position for inline to pick back up.
///
/// Self-contained controls (scrub slider, time labels, ±10s, play/pause) bound
/// to its own controller — it does not touch `PlayerView`'s inline `vlc`.
private struct VLCFullscreenView: View {
    let streamURL: URL
    /// Clean video title shown centered in the top bar (e.g. the filename).
    let title: String
    /// The landscape-shaped frame this whole view is laid out in (portrait
    /// width/height swapped) BEFORE the wrapper rotates it 90°. Video + chrome
    /// share this frame; it also doubles as the VLC Fill/Cover drawable surface.
    let landscapeSize: CGSize
    /// Safe-area insets already remapped into the landscape frame by the wrapper,
    /// so the chrome keeps the close button and transport clear of the notch /
    /// Dynamic Island / home indicator after the 90° rotation.
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

    /// Seconds the controls stay visible before auto-hiding during playback.
    private let autoHideDelay: TimeInterval = 3


    var body: some View {
        // Laid out in the LANDSCAPE frame (`landscapeSize`); the wrapper rotates
        // this whole view 90° to fill the tilted phone. Video + chrome share one
        // landscape coordinate space and one rotation, so bars/title/clock/times/
        // timeline are all horizontal to the user — no per-element rotation. The
        // native status bar is hidden the whole time (see `.statusBarHidden`), so
        // the top bar carries its own clock.
        ZStack {
            // Video fills the landscape frame; VLC preserves aspect internally
            // and letterboxes against the black backdrop.
            VLCPlayerView(url: streamURL, controller: fsVlc)
                .frame(width: landscapeSize.width, height: landscapeSize.height)

            // Full-area tap target to toggle controls. Above the video, below the
            // bars/buttons so those still receive their own taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            // State overlay (spinner / replay) centered over the video.
            overlay

            // Sidecar `.srt` subtitle overlay — bottom-centered. Holds its position
            // in BOTH Fit and Cover (native VLC subtitles shift with the Cover
            // crop). Lifts when controls are up so it clears the bottom bar.
            VStack {
                Spacer()
                SubtitleOverlay(text: fsVlc.currentSubtitleText)
                    .padding(.bottom, controlsVisible ? 116 : 28)
            }
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)

            if controlsVisible {
                // nPlayer-style chrome: a translucent top bar (close, times,
                // title, subtitle menu) across the top, and a translucent bottom
                // bar (timeline + transport) across the bottom, with a floating
                // Fit/Cover pill. All fade together with the controls.
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
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
        .onAppear { scheduleAutoHide() }
        // The controller's media frees with the view; `teardown` also persists
        // position and stops audio so inline can resume cleanly.
        .onDisappear {
            autoHideTask?.cancel()
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

    /// Device wall-clock formatted for the top bar, honoring the user's 12/24h
    /// locale setting (e.g. "16:25" or "4:25 PM"). Driven by `TimelineView`.
    private func clockText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
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
                .buttonStyle(.plain)
            }
        case .ready:
            EmptyView()
        }
    }

    /// Translucent top bar: close • clock • elapsed • title • remaining • menu.
    /// A thin material with a fading scrim keeps the text legible over any frame
    /// while still letting the video read through. The native iOS status bar is
    /// hidden in fullscreen (see `.statusBarHidden(true)`), so this bar carries
    /// its own live wall-clock instead.
    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: closeFullscreen) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Live device wall-clock (e.g. "16:25"), replacing the hidden native
            // status-bar time. `TimelineView(.periodic)` re-renders each minute
            // boundary is enough, but ticking every 30s keeps it within a minute
            // of accurate without a manual Timer.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(clockText(context.date))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white)
            }

            Text(fsVlc.currentTimeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(fsVlc.remainingTimeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))

            // "More" area: the subtitle menu when subtitles exist, else a
            // fixed-width spacer so the title stays optically centered.
            Group {
                if fsVlc.hasSidecarSubtitle || fsVlc.hasSubtitles {
                    subtitleButton
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
        }
        .padding(.leading, 20 + safeInsets.leading)
        .padding(.trailing, 20 + safeInsets.trailing)
        .padding(.top, 10 + safeInsets.top)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial.opacity(0.5))
        )
    }

    /// Translucent bottom bar: full-width scrub slider with the transport row
    /// centered beneath it, and the Fit/Cover pill floating at the trailing edge.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            TimelineSlider(
                progress: $fsVlc.progress,
                onScrubBegan: { fsVlc.beginScrubbing() },
                onScrubEnded: { fraction in
                    fsVlc.endScrubbing(to: fraction)
                    if controlsVisible { scheduleAutoHide() }
                }
            )
            .frame(height: 28)

            HStack(spacing: 44) {
                transportButton(systemName: "gobackward.10", font: .title2) {
                    fsVlc.skipBackward()
                }
                transportButton(
                    systemName: fsVlc.isPlaying ? "pause.fill" : "play.fill",
                    font: .system(size: 42)
                ) {
                    fsVlc.togglePlayPause()
                }
                transportButton(systemName: "goforward.10", font: .title2) {
                    fsVlc.skipForward()
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { ratioButton }
        }
        .padding(.leading, 24 + safeInsets.leading)
        .padding(.trailing, 24 + safeInsets.trailing)
        .padding(.top, 12)
        .padding(.bottom, 14 + safeInsets.bottom)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial.opacity(0.5))
        )
    }

    /// Subtitle picker. Shown ONLY when subtitles are available, so a video
    /// without any never shows a dead control. Re-arms the auto-hide timer so
    /// changing the choice doesn't hide the controls.
    ///   - Sidecar `.srt` present → simple "Subtitles / Off" toggle for the
    ///     stable SwiftUI overlay (native tracks are hidden — overlay is sole
    ///     source).
    ///   - Otherwise → "Off" plus each embedded native track, checkmark on the
    ///     active one.
    @ViewBuilder
    private var subtitleButton: some View {
        if fsVlc.hasSidecarSubtitle {
            Menu {
                Button {
                    fsVlc.setSidecarEnabled(true)
                    if controlsVisible { scheduleAutoHide() }
                } label: {
                    Label("Subtitles", systemImage: fsVlc.sidecarEnabled ? "checkmark" : "")
                }
                Button {
                    fsVlc.setSidecarEnabled(false)
                    if controlsVisible { scheduleAutoHide() }
                } label: {
                    Label("Off", systemImage: fsVlc.sidecarEnabled ? "" : "checkmark")
                }
            } label: { subtitleButtonLabel(on: fsVlc.sidecarEnabled) }
            .padding(.leading, 4)
        } else if fsVlc.hasSubtitles {
            Menu {
                Button {
                    fsVlc.selectSubtitle(index: -1)
                    if controlsVisible { scheduleAutoHide() }
                } label: {
                    Label("Off", systemImage: fsVlc.currentSubtitleIndex == -1 ? "checkmark" : "")
                }
                ForEach(fsVlc.subtitleTracks) { track in
                    Button {
                        fsVlc.selectSubtitle(index: track.index)
                        if controlsVisible { scheduleAutoHide() }
                    } label: {
                        Label(
                            track.name,
                            systemImage: fsVlc.currentSubtitleIndex == track.index ? "checkmark" : ""
                        )
                    }
                }
            } label: { subtitleButtonLabel(on: fsVlc.currentSubtitleIndex != -1) }
            .padding(.leading, 4)
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
        .buttonStyle(.plain)
        .padding(.trailing, 4)
    }

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
        .buttonStyle(.plain)
    }
}

/// nPlayer-style scrub timeline: a dim full-width track with a tinted "watched"
/// fill and a clean draggable thumb. Replaces the system `Slider` for full
/// control over the filled/unfilled look. Seek behavior is unchanged — it drives
/// the same controller scrub callbacks:
///   - `onScrubBegan` once when a drag starts (freezes live progress updates),
///   - `onScrubEnded(fraction)` when the drag ends (performs the seek).
/// While dragging it updates the bound `progress` so the fill/thumb track the
/// finger; the controller suppresses its own progress writes during the drag.
private struct TimelineSlider: View {
    @Binding var progress: Double
    let onScrubBegan: () -> Void
    let onScrubEnded: (Double) -> Void

    /// True between drag start and end, so the gesture only fires `onScrubBegan`
    /// once and maps subsequent moves to the live fill.
    @State private var dragging = false

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(progress, 0), 1)
            let fillWidth = width * CGFloat(clamped)

            ZStack(alignment: .leading) {
                // Unfilled (remaining) track — dim.
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: trackHeight)

                // Watched (filled) track — tinted.
                Capsule()
                    .fill(.tint)
                    .frame(width: fillWidth, height: trackHeight)

                // Thumb — clean white circle centered on the playhead, kept
                // inside the track bounds at the extremes.
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: min(max(fillWidth - thumbSize / 2, 0), width - thumbSize))
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
                url: "http://100.92.146.101:8090/files/Sample/Big%20Buck%20Bunny.mp4",
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
                url: "http://100.92.146.101:8090/files/Sample/Movie.mkv",
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
