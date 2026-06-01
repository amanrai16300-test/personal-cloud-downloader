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
        .onDisappear {
            player?.pause()
            vlc.stop()
        }
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: {
            // Back to where the user was before fullscreen (usually portrait).
            OrientationHelper.restore(orientationBeforeFullscreen)
        }) {
            if let streamURL = video.streamURL {
                fullscreenContent(streamURL)
                    // Rotate to landscape once the fullscreen player is up.
                    .onAppear { OrientationHelper.lockLandscape() }
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
                // `savedPositions` store. No padding — it fills the screen edge
                // to edge as a real fullscreen video surface. The close button
                // lives inside it so it auto-hides with the controls.
                VLCFullscreenView(streamURL: streamURL) {
                    isFullscreen = false
                }
            }
        }
    }

    /// Top-trailing button overlaid on a player surface to enter fullscreen.
    /// For VLC, tear the inline player down first (persists position, stops
    /// audio, frees the drawable) so the fullscreen surface — a SEPARATE VLC
    /// controller — starts clean with no second player still holding audio.
    private var fullscreenButton: some View {
        Button {
            // Capture orientation before rotating so exit can restore it.
            orientationBeforeFullscreen = OrientationHelper.currentOrientation()
            if !video.isAVPlayerSupported {
                vlc.teardown()
            }
            isFullscreen = true
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

    private func vlcPlayback(_ streamURL: URL) -> some View {
        VStack(spacing: Layout.sectionSpacing) {
            vlcSurface(streamURL, liveVideo: !isFullscreen)

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
        ZStack {
            Color.black

            // Video fills the whole screen; VLC preserves aspect internally and
            // letterboxes against the black backdrop. No 16:9 box, no padding —
            // this is the actual fullscreen surface.
            VLCPlayerView(url: streamURL, controller: fsVlc)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Full-area tap target to toggle controls. Must sit above the video
            // but below the controls so buttons still receive their own taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            // State overlay (spinner / replay) centered over the video.
            overlay

            if controlsVisible {
                // Close button, top-leading. Fades with the controls.
                VStack {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white, .black.opacity(0.4))
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding()
                .transition(.opacity)

                // Transport controls float over the bottom of the video on a
                // scrim so they don't shrink the picture.
                VStack {
                    Spacer()
                    controls
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .ignoresSafeArea(edges: .bottom)
                        )
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear { scheduleAutoHide() }
        // The controller's media frees with the view; `teardown` also persists
        // position and stops audio so inline can resume cleanly.
        .onDisappear {
            autoHideTask?.cancel()
            fsVlc.teardown()
        }
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

    private var controls: some View {
        VStack(spacing: 6) {
            Slider(
                value: $fsVlc.progress,
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        fsVlc.beginScrubbing()
                    } else {
                        fsVlc.endScrubbing(to: fsVlc.progress)
                    }
                }
            )

            HStack {
                Text(fsVlc.currentTimeText)
                Spacer()
                Text(fsVlc.durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 40) {
                transportButton(systemName: "gobackward.10", font: .title2) {
                    fsVlc.skipBackward()
                }
                transportButton(
                    systemName: fsVlc.isPlaying ? "pause.fill" : "play.fill",
                    font: .system(size: 44)
                ) {
                    fsVlc.togglePlayPause()
                }
                transportButton(systemName: "goforward.10", font: .title2) {
                    fsVlc.skipForward()
                }
            }
            .foregroundStyle(.white)
            .padding(.top, 6)
        }
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
