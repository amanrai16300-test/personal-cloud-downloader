import SwiftUI
import AVKit
import Combine

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
        .fullScreenCover(isPresented: $isFullscreen) {
            if let streamURL = video.streamURL {
                fullscreenContent(streamURL)
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

            Group {
                if video.isAVPlayerSupported {
                    avSurface
                } else {
                    VStack(spacing: 12) {
                        vlcSurface(streamURL)
                        vlcControls(streamURL)
                    }
                }
            }
            .padding()

            Button {
                isFullscreen = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            .padding()
        }
    }

    /// Top-trailing button overlaid on a player surface to enter fullscreen.
    private var fullscreenButton: some View {
        Button {
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

    /// Shared VLC rendering surface (16:9) with state overlay and the
    /// enter-fullscreen button. Reused by inline and fullscreen presentations.
    private func vlcSurface(_ streamURL: URL) -> some View {
        framedSurface(
            VLCPlayerView(url: streamURL, controller: vlc)
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
            vlcSurface(streamURL)

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
