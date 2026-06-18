import Foundation
import SwiftUI

/// CloudBox Home: a private-cloud dashboard with one telemetry panel, an
/// asymmetric metrics bento, and a single action row. Visual language is
/// deliberately restrained — deep navy surfaces, hairline strokes, one blue
/// accent, monospaced telemetry — so it reads handcrafted rather than
/// template-like.
///
/// Data layer: one aggregated `GET /api/home-dashboard` request feeds server,
/// library, downloads, network, Continue Watching, and Recently Added. Request
/// round-trip time is measured client-side for the latency readout. Media taps
/// reuse the existing VideosView → PlayerView flow: the home item is matched to
/// the real `CompletedFile` (for the correct stream URL + AVPlayer/VLC routing)
/// and its saved-resume position is seeded before pushing the player.
struct HomeView: View {
    private let serverIP = "100.95.39.107"
    private let backendBaseURL = CompletedFilesAPI.baseURL
    private let refreshInterval: UInt64 = 12_000_000_000

    // MARK: Palette — semantic tokens, used consistently across the screen.
    private let screenBackground = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let surface = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let surfaceRaised = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let hairline = Color.white.opacity(0.08)
    private let mutedText = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)
    private let videosViolet = Color(red: 0.64, green: 0.52, blue: 1.0)
    private let filesTeal = Color(red: 0.28, green: 0.76, blue: 0.70)

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashboard = HomeDashboardState()
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = 0
    /// Pushed when a media card is tapped — the matched real `CompletedFile`,
    /// which drives PlayerView's stream URL and AVPlayer/VLC routing.
    @State private var selectedVideo: CompletedFile?

    /// Drives the player push (iOS 16-compatible). Clearing on pop releases the
    /// matched file so a later tap re-matches fresh.
    private var playerPresented: Binding<Bool> {
        Binding(
            get: { selectedVideo != nil },
            set: { presented in if !presented { selectedVideo = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    brandHeader
                    serverPanel
                    metricsBento
                    continueWatchingSection
                    recentlyAddedSection
                    tailscaleAction
                    privateCloudNote
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                // One animation driver for the whole dashboard: counts and
                // status text settle with a short ease whenever fresh data
                // lands (contentTransition handles the digit morph).
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: dashboard.lastUpdated)
            }
            .background(homeBackground)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // A tapped media card pushes the existing fullscreen player, exactly
            // as the Videos list does (same CompletedFile destination + flow).
            // Programmatic push via a binding (iOS 16-compatible: no
            // `navigationDestination(item:)`, which is iOS 17+).
            .navigationDestination(isPresented: playerPresented) {
                if let video = selectedVideo {
                    PlayerView(video: video, startsFullscreen: true)
                }
            }
            // A tapped grouped-series card pushes the exact same folder/episode
            // picker the Videos tab uses (FolderVideosView), where the user
            // selects an episode. No second episode list is built in Home.
            .navigationDestination(for: VideoFolder.self) { folder in
                FolderVideosView(folder: folder, progressByPath: [:])
            }
            .refreshable {
                await refreshDashboard()
            }
            .onAppear {
                startRefreshLoop()
            }
            .onDisappear {
                stopRefreshLoop()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    startRefreshLoop(foregroundReconnect: dashboard.hasLoaded)
                } else {
                    stopRefreshLoop()
                }
            }
        }
    }

    // MARK: Background — deep navy with ONE soft accent bloom, no busy gradients.

    private var homeBackground: some View {
        ZStack {
            screenBackground.ignoresSafeArea()
            RadialGradient(
                colors: [premiumBlue.opacity(0.14), .clear],
                center: .init(x: 0.85, y: -0.05),
                startRadius: 10,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Brand header — wordmark + live subtitle, no card chrome.

    private var brandHeader: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [premiumBlue, Color(red: 0.07, green: 0.22, blue: 0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    }

                Image(systemName: "cloud.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .shadow(color: premiumBlue.opacity(0.35), radius: 12, y: 6)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("CloudBox")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)

                Text(dashboard.headerSubtitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: Server panel — the screen's telemetry centerpiece.

    /// Private-tailnet panel: status orb + label, monospaced server address,
    /// and an updated/refresh footer. Dot-grid texture + corner bloom give it
    /// a quiet "infrastructure" character instead of a generic stat card.
    private var serverPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("PRIVATE TAILNET")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(premiumBlue)

                Spacer(minLength: 8)

                StatusOrb(color: serverStatusColor, animates: !reduceMotion)

                Text(dashboard.serverStatusText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(serverStatusColor)
                    .contentTransition(.opacity)
            }
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(premiumBlue)
                    .accessibilityHidden(true)

                Text(serverIP)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                    .accessibilityLabel("Server address \(serverIP)")

                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            Rectangle()
                .fill(hairline)
                .frame(height: 1)
                .padding(.bottom, 11)

            HStack(spacing: 6) {
                Image(systemName: dashboard.isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mutedText)
                    .accessibilityHidden(true)

                Text("Updated")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mutedText)

                Text(dashboard.lastUpdatedText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .contentTransition(.opacity)

                Spacer(minLength: 8)

                Text(dashboard.latencyText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(mutedText.opacity(0.85))
                    .contentTransition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(surface)

                // Quiet infrastructure texture — static, cheap to draw.
                DotGrid()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                RadialGradient(
                    colors: [premiumBlue.opacity(0.16), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 240
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.45), hairline],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: Metrics bento — one wide card + a pair, instead of a uniform grid.

    private var metricsBento: some View {
        VStack(spacing: 12) {
            downloaderCard

            HStack(spacing: 12) {
                compactMetricCard(
                    icon: "play.rectangle.fill",
                    title: "Videos",
                    value: dashboard.completedFilesText,
                    detail: "Completed files",
                    tint: videosViolet
                )

                compactMetricCard(
                    icon: "externaldrive.fill",
                    title: "Files",
                    value: dashboard.filesIndexText,
                    detail: dashboard.filesIndexDetail,
                    tint: filesTeal
                )
            }
        }
    }

    /// Wide downloader card: count dominates, wave ornament fills the trailing
    /// space. The asymmetry (one wide + two compact) is what keeps the bento
    /// from reading as a template grid.
    private var downloaderCard: some View {
        HStack(alignment: .center, spacing: 14) {
            iconChip("arrow.down.circle.fill", tint: premiumBlue)

            VStack(alignment: .leading, spacing: 3) {
                Text("Downloader")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(mutedText)

                Text(dashboard.torrentCountText)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())

                Text(dashboard.activeTorrentText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            WaveLines(tint: premiumBlue.opacity(0.30))
                .frame(width: 110, height: 58)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(metricSurface(tint: premiumBlue))
        .accessibilityElement(children: .combine)
    }

    private func compactMetricCard(
        icon: String,
        title: String,
        value: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                iconChip(icon, tint: tint)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())

                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(metricSurface(tint: tint))
        .accessibilityElement(children: .combine)
    }

    /// Shared metric-card surface: flat raised navy, hairline stroke, and a
    /// whisper of the card's tint along the top edge. No glow shadows.
    private func metricSurface(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(surfaceRaised)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [tint.opacity(0.14), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }

    /// Small tinted icon chip shared by every metric card — one size, one
    /// stroke, one icon family.
    private func iconChip(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(tint.opacity(0.30), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    // MARK: Continue Watching — one wide resume card, or nothing when absent.

    /// Rendered only when the backend returns a Continue Watching item; absent
    /// (no card, no header) otherwise so the layout stays quiet. Tapping opens
    /// the existing player at the saved position.
    @ViewBuilder
    private var continueWatchingSection: some View {
        if let item = dashboard.continueWatching {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("CONTINUE WATCHING")

                Button {
                    openMedia(item)
                } label: {
                    HStack(spacing: 13) {
                        mediaArtwork(item, wide: true, width: 124, height: 70)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            if let subtitle = item.subtitleText {
                                Text(subtitle)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(mutedText)
                                    .lineLimit(1)
                            }

                            mediaProgressBar(item.progressFraction)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 8)

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(premiumBlue)
                            .accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(metricSurface(tint: premiumBlue))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(HomePressStyle())
            }
        }
    }

    // MARK: Recently Added — horizontal poster strip, hidden when empty.

    @ViewBuilder
    private var recentlyAddedSection: some View {
        if !dashboard.recentlyAddedEntries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("RECENTLY ADDED")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(dashboard.recentlyAddedEntries) { entry in
                            switch entry.kind {
                            case .movie(let item):
                                Button {
                                    openMedia(item)
                                } label: {
                                    recentlyAddedCard(
                                        item: item,
                                        title: entry.displayTitle,
                                        episodeCount: nil
                                    )
                                }
                                .buttonStyle(HomePressStyle())

                            case .series(let folder, let item):
                                // Tapping opens the existing folder/episode
                                // picker (same screen as the Videos tab).
                                NavigationLink(value: folder) {
                                    recentlyAddedCard(
                                        item: item,
                                        title: entry.displayTitle,
                                        episodeCount: folder.videos.count
                                    )
                                }
                                .buttonStyle(HomePressStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    /// One Recently Added poster card. Movies and grouped series share the same
    /// layout; series add an episode-count badge over the artwork. `item`
    /// supplies the artwork (poster_url → local_thumbnail_url → placeholder) and,
    /// for series, the chosen representative episode's poster.
    private func recentlyAddedCard(item: HomeMediaItem, title: String, episodeCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            mediaArtwork(item, wide: false, width: 116, height: 164)
                .overlay(alignment: .topTrailing) {
                    if let episodeCount {
                        Text(episodeCount == 1 ? "1 ep" : "\(episodeCount) eps")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.70), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                            .padding(7)
                    }
                }

            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 116, alignment: .leading)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(premiumBlue)
    }

    /// Artwork for a media card. TMDB poster/backdrop are preferred when present
    /// (backdrop for the wide Continue Watching card, poster for portrait
    /// Recently Added), falling back to the local thumbnail, then a placeholder.
    /// Visual only — never used for playback identity.
    @ViewBuilder
    private func mediaArtwork(_ item: HomeMediaItem, wide: Bool, width: CGFloat, height: CGFloat) -> some View {
        let url = wide ? item.wideArtworkURL : item.portraitArtworkURL
        let radius: CGFloat = wide ? 10 : 12
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        mediaArtworkPlaceholder
                    }
                }
            } else {
                mediaArtworkPlaceholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var mediaArtworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.14),
                        Color(red: 0.045, green: 0.055, blue: 0.07),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.28))
            }
    }

    private func mediaProgressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(premiumBlue)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }

    // MARK: Tailscale action — the screen's single tappable row.

    private var tailscaleAction: some View {
        Link(destination: URL(string: "tailscale://")!) {
            HStack(spacing: 13) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "globe")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(red: 0.62, green: 0.80, blue: 1.0))
                        .frame(width: 46, height: 46)
                        .background(premiumBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(premiumBlue.opacity(0.32), lineWidth: 1)
                        }

                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 18, height: 18)
                        .background(premiumBlue, in: Circle())
                        .offset(x: 5, y: 5)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Tailscale")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text("Private connection / VPN route")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(mutedText)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(premiumBlue)
                    .frame(width: 34, height: 34)
                    .background(premiumBlue.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(premiumBlue.opacity(0.30), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
    }

    // MARK: Footer note — quiet, no card competition.

    private var privateCloudNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(mutedText)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text("Private CloudBox access stays behind Tailscale. Offline values mean the phone cannot reach the server right now.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Status mapping (unchanged behavior)

    private var serverStatusColor: Color {
        if dashboard.isCheckingUnknownServer {
            return .secondary
        }

        switch dashboard.serverStatus {
        case .loading:
            return .secondary
        case .online:
            return .green
        case .offline:
            return .red
        }
    }

    // MARK: Media open — reuse the existing VideosView → PlayerView flow.

    /// Open the existing player for a home media item. The home payload omits the
    /// stream URL (and AVPlayer/VLC routing keys off the file extension), so the
    /// item is matched to the real `CompletedFile` from `/api/completed-files`
    /// by its stable relative path — the same identity VideosView uses. Resume
    /// is seeded into the shared saved-position store (keyed by the matched
    /// file's `path`, the VLC resume key) so playback resumes at the backend
    /// `position_seconds`. Playback never uses the artwork/thumbnail.
    private func openMedia(_ item: HomeMediaItem) {
        Task {
            let matched = await matchCompletedFile(for: item)
            await MainActor.run {
                guard let matched else { return }
                seedResume(for: matched, item: item)
                selectedVideo = matched
            }
        }
    }

    /// Find the `CompletedFile` whose relative path matches the home item's
    /// `relativePath` / `videoId`. Both the backend home item and `CompletedFile`
    /// use the completed-files relative path as the stable identifier.
    private func matchCompletedFile(for item: HomeMediaItem) async -> CompletedFile? {
        guard let videos = try? await CompletedFilesAPI.fetchVideos() else { return nil }
        let target = item.relativePath
        return videos.first { normalizePath($0.path) == normalizePath(target) || normalizePath($0.name) == normalizePath(target) }
    }

    private func normalizePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// Seed the saved-resume position so the VLC engine resumes at the backend
    /// `position_seconds`. Keyed by the matched file's `path` (PlayerView's VLC
    /// `resumeKey`). Only seeds when a real duration is known (the store ignores
    /// zero-duration entries). Native AVPlayer formats don't resume in this app,
    /// so this affects mkv/avi/webm — matching existing behavior.
    private func seedResume(for matched: CompletedFile, item: HomeMediaItem) {
        guard item.durationSeconds > 0, item.positionSeconds > 0 else { return }
        let progress = VideoProgress.local(
            path: matched.path,
            timeMs: item.positionSeconds * 1000,
            durationMs: item.durationSeconds * 1000
        )
        VLCPlayerController.importProgressSnapshot([matched.path: progress])
    }

    // MARK: Refresh loop (unchanged behavior)

    private func startRefreshLoop() {
        startRefreshLoop(foregroundReconnect: false)
    }

    private func startRefreshLoop(foregroundReconnect: Bool) {
        refreshTask?.cancel()
        refreshGeneration += 1
        refreshTask = Task {
            await refreshDashboard(foregroundReconnect: foregroundReconnect)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshInterval)
                guard !Task.isCancelled else { return }
                await refreshDashboard()
            }
        }
    }

    private func stopRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
    }

    private func refreshDashboard() async {
        await refreshDashboard(foregroundReconnect: false)
    }

    private func refreshDashboard(foregroundReconnect: Bool) async {
        let generation = await MainActor.run {
            refreshGeneration += 1
            dashboard.isRefreshing = true
            dashboard.isReconnecting = foregroundReconnect
            if !dashboard.hasLoaded || foregroundReconnect {
                dashboard.serverStatus = .loading
            }
            return refreshGeneration
        }

        if foregroundReconnect {
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
        }

        let result = foregroundReconnect
            ? await fetchDashboardWithRetries()
            : await fetchDashboard()

        // Resolve Recently Added grouping off the main actor: match each item to
        // its real CompletedFile and group by torrent folder (the same identity
        // VideosView uses). TV episodes sharing a folder collapse into one series
        // entry; everything else stays an individual (movie) card.
        let entries = await makeRecentlyAddedEntries(from: result?.response.recentlyAdded ?? [])

        await MainActor.run {
            guard generation == refreshGeneration else { return }
            dashboard.isReconnecting = false
            dashboard = makeState(from: result, recentlyAddedEntries: entries)
        }
    }

    /// Build the view state from a fetch outcome, preserving the existing
    /// online/offline semantics: a failed fetch is "offline" with cleared
    /// counts, a success is "online" with whatever fields decoded.
    private func makeState(from result: DashboardFetch?, recentlyAddedEntries: [RecentlyAddedEntry]) -> HomeDashboardState {
        guard let result else {
            return HomeDashboardState(
                serverStatus: .offline,
                lastUpdated: Date(),
                isRefreshing: false,
                isReconnecting: false,
                hasLoaded: true
            )
        }

        let response = result.response
        return HomeDashboardState(
            serverStatus: (response.server?.online ?? true) ? .online : .offline,
            torrentCount: response.downloads?.activeCount,
            completedFileCount: response.library?.videoCount,
            indexedFileCount: response.library?.fileCount,
            latencyMs: result.latencyMs,
            continueWatching: response.continueWatching,
            recentlyAdded: response.recentlyAdded ?? [],
            recentlyAddedEntries: recentlyAddedEntries,
            lastUpdated: Date(),
            isRefreshing: false,
            isReconnecting: false,
            hasLoaded: true
        )
    }

    /// Resolve the flat Recently Added payload into display entries: TV episodes
    /// that share a torrent folder collapse into one series card (opening the
    /// existing FolderVideosView episode picker); movies / single files stay as
    /// individual cards (opening the existing player).
    ///
    /// Grouping reuses VideoGrouping over the real CompletedFile list, so a
    /// series card shows the *complete* folder — the same folder VideosView would
    /// — not just the episodes that happen to be in the home payload. Series are
    /// positioned by their newest member episode's timestamp; the original
    /// Recently Added order (already newest-first from the backend) is otherwise
    /// preserved, and each series appears once.
    private func makeRecentlyAddedEntries(from items: [HomeMediaItem]) async -> [RecentlyAddedEntry] {
        guard !items.isEmpty else { return [] }

        // Full library, grouped exactly like the Videos tab. If it can't be
        // fetched, fall back to one movie card per item in the backend's order
        // (newest-first), preserving prior behavior so the strip still renders
        // and still opens the player.
        guard let videos = try? await CompletedFilesAPI.fetchVideos() else {
            return items.enumerated().map { index, item in
                RecentlyAddedEntry(kind: .movie(item), sortDate: backendOrderDate(at: index))
            }
        }

        let grouped = VideoGrouping.group(videos)
        // Folder name (series key) → its complete VideoFolder.
        let folderByName = Dictionary(uniqueKeysWithValues: grouped.folders.map { ($0.name, $0) })

        var entries: [RecentlyAddedEntry] = []
        var seenSeries: Set<String> = []

        for (index, item) in items.enumerated() {
            // Which folder does this item's file belong to? Match by relative
            // path, then take its first path component (VideoGrouping's series
            // key). A multi-video folder is a TV series; otherwise it's a movie.
            let matched = matchVideo(for: item, in: videos)
            if let matched,
               let folderName = VideoGrouping.folderName(of: matched),
               let folder = folderByName[folderName],
               folder.videos.count > 1 {
                guard seenSeries.insert(folderName).inserted else { continue }
                // Position the series by its newest episode timestamp; fall back
                // to the backend's newest-first ordering if no dates parse.
                let newest = folder.videos.compactMap(\.modifiedDate).max() ?? backendOrderDate(at: index)
                entries.append(RecentlyAddedEntry(kind: .series(folder, item), sortDate: newest))
            } else {
                let date = matched?.modifiedDate ?? backendOrderDate(at: index)
                entries.append(RecentlyAddedEntry(kind: .movie(item), sortDate: date))
            }
        }

        return entries.sorted { $0.sortDate > $1.sortDate }
    }

    /// A synthetic descending timestamp that preserves the backend's newest-first
    /// Recently Added order when a real `modified_at` is unavailable (earlier
    /// index → more recent).
    private func backendOrderDate(at index: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: -Double(index))
    }

    /// Synchronous CompletedFile match against an already-fetched list, mirroring
    /// `matchCompletedFile`'s path/name identity (used for grouping only).
    private func matchVideo(for item: HomeMediaItem, in videos: [CompletedFile]) -> CompletedFile? {
        let target = item.relativePath
        return videos.first { normalizePath($0.path) == normalizePath(target) || normalizePath($0.name) == normalizePath(target) }
    }

    private func fetchDashboardWithRetries() async -> DashboardFetch? {
        for attempt in 1...3 {
            if let result = await fetchDashboard() {
                return result
            }
            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                return nil
            }
        }
        return nil
    }

    /// One aggregated request. Measures the round-trip time client-side for the
    /// latency readout (the backend deliberately does not compute latency).
    private func fetchDashboard() async -> DashboardFetch? {
        guard let url = URL(string: "\(backendBaseURL)/api/home-dashboard") else { return nil }

        let start = DispatchTime.now()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(HomeDashboardResponse.self, from: data)
            return DashboardFetch(response: decoded, latencyMs: Int(elapsedNs / 1_000_000))
        } catch {
            return nil
        }
    }
}

/// A successful dashboard fetch plus the measured client round-trip latency.
private struct DashboardFetch {
    let response: HomeDashboardResponse
    let latencyMs: Int
}

// MARK: - Backend response models (GET /api/home-dashboard)

/// Decodes the aggregated Home response. Every section is optional so one
/// failed/absent service never fails the whole decode — missing pieces simply
/// render as their offline/empty fallbacks.
private struct HomeDashboardResponse: Decodable {
    let server: ServerInfo?
    let library: LibraryInfo?
    let downloads: DownloadsInfo?
    let network: NetworkInfo?
    let continueWatching: HomeMediaItem?
    let recentlyAdded: [HomeMediaItem]?

    enum CodingKeys: String, CodingKey {
        case server, library, downloads, network
        case continueWatching = "continue_watching"
        case recentlyAdded = "recently_added"
    }

    struct ServerInfo: Decodable {
        let online: Bool?
        let location: String?
        let uptimeSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case online, location
            case uptimeSeconds = "uptime_seconds"
        }
    }

    struct LibraryInfo: Decodable {
        let videoCount: Int?
        let fileCount: Int?

        enum CodingKeys: String, CodingKey {
            case videoCount = "video_count"
            case fileCount = "file_count"
        }
    }

    struct DownloadsInfo: Decodable {
        let activeCount: Int?

        enum CodingKeys: String, CodingKey {
            case activeCount = "active_count"
        }
    }

    struct NetworkInfo: Decodable {
        let rxBytesPerSecond: Int?
        let txBytesPerSecond: Int?

        enum CodingKeys: String, CodingKey {
            case rxBytesPerSecond = "rx_bytes_per_second"
            case txBytesPerSecond = "tx_bytes_per_second"
        }
    }
}

/// One Home media item (Continue Watching or Recently Added). Playback identity
/// is `videoId` / `relativePath` (the completed-files relative path); poster /
/// backdrop are optional artwork only, with `localThumbnailURL` as fallback.
private struct HomeMediaItem: Decodable, Identifiable, Hashable {
    let videoId: String
    let relativePath: String
    let filename: String
    let title: String
    let subtitle: String?
    let positionSeconds: Int
    let durationSeconds: Int
    let progress: Double
    let localThumbnailURL: String?
    let posterURL: String?
    let backdropURL: String?
    let year: Int?

    var id: String { videoId }

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case relativePath = "relative_path"
        case filename, title, subtitle, progress, year
        case positionSeconds = "position_seconds"
        case durationSeconds = "duration_seconds"
        case localThumbnailURL = "local_thumbnail_url"
        case posterURL = "poster_url"
        case backdropURL = "backdrop_url"
    }

    /// Release year as display text (e.g. "2022"), if the backend supplied a
    /// plausible one. nil → no year shown.
    var yearText: String? {
        guard let year, year > 0 else { return nil }
        return String(year)
    }

    /// Normalized 0.0–1.0 progress from the backend, clamped defensively.
    var progressFraction: Double { min(max(progress, 0), 1) }

    var subtitleText: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }

    /// Wide artwork (Continue Watching): TMDB backdrop preferred, else the local
    /// thumbnail. nil → placeholder.
    var wideArtworkURL: URL? {
        validURL(backdropURL) ?? validURL(localThumbnailURL)
    }

    /// Portrait artwork (Recently Added): TMDB poster preferred, else the local
    /// thumbnail. nil → placeholder.
    var portraitArtworkURL: URL? {
        validURL(posterURL) ?? validURL(localThumbnailURL)
    }

    private func validURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

/// One Recently Added strip entry: either an individual movie/single file (opens
/// the player) or a grouped TV series (opens the existing folder/episode picker).
private struct RecentlyAddedEntry: Identifiable {
    enum Kind {
        /// A standalone file — tapping opens PlayerView via `openMedia`.
        case movie(HomeMediaItem)
        /// A grouped series: the complete folder to push, plus a representative
        /// home item supplying the poster/thumbnail artwork.
        case series(VideoFolder, HomeMediaItem)
    }

    let kind: Kind
    /// Drives Recently Added ordering (newest first).
    let sortDate: Date

    var id: String {
        switch kind {
        case .movie(let item): return "movie:\(item.id)"
        case .series(let folder, _): return "series:\(folder.id)"
        }
    }

    /// Display title with the backend `year` appended when present (e.g.
    /// "Severance (2022)"). Series use the folder name as the base; movies use
    /// the item title. The year is taken straight from the dashboard payload —
    /// not parsed from the title — and skipped if the base already contains it.
    var displayTitle: String {
        switch kind {
        case .movie(let item):
            return Self.titled(item.title, year: item.yearText)
        case .series(let folder, let item):
            return Self.titled(folder.name, year: item.yearText)
        }
    }

    private static func titled(_ base: String, year: String?) -> String {
        guard let year, !base.contains(year) else { return base }
        return "\(base) (\(year))"
    }
}

/// Live status indicator: a solid dot with a slow expanding pulse ring.
/// The pulse is purely decorative, runs on transform/opacity only, and is
/// disabled entirely under Reduce Motion.
private struct StatusOrb: View {
    let color: Color
    let animates: Bool

    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1)
                .frame(width: 9, height: 9)
                .scaleEffect(pulsing ? 2.1 : 1)
                .opacity(pulsing ? 0 : 0.8)

            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            guard animates else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HomeDashboardState {
    var serverStatus: HomeServerStatus = .loading
    var torrentCount: Int?
    var completedFileCount: Int?
    var indexedFileCount: Int?
    var latencyMs: Int?
    var continueWatching: HomeMediaItem?
    var recentlyAdded: [HomeMediaItem] = []
    var recentlyAddedEntries: [RecentlyAddedEntry] = []
    var lastUpdated: Date?
    var isRefreshing = false
    var isReconnecting = false
    var hasLoaded = false

    var torrentCountText: String {
        guard let torrentCount else { return "Offline" }
        return "\(torrentCount)"
    }

    var activeTorrentText: String {
        guard let torrentCount else { return "No connection" }
        return torrentCount == 1 ? "Active download" : "Active downloads"
    }

    var completedFilesText: String {
        guard let completedFileCount else { return "Offline" }
        return "\(completedFileCount)"
    }

    var filesIndexText: String {
        indexedFileCount == nil ? "Offline" : "Indexed"
    }

    var filesIndexDetail: String {
        guard let indexedFileCount else { return "No connection" }
        return indexedFileCount == 1 ? "1 completed item" : "\(indexedFileCount) completed items"
    }

    var latencyText: String {
        if isReconnecting || isRefreshing { return "Oracle · Tokyo" }
        guard let latencyMs else { return "Oracle · Tokyo" }
        return "\(latencyMs) ms"
    }

    var headerSubtitle: String {
        if isReconnecting {
            return "Reconnecting to the private shelf"
        }

        if isCheckingUnknownServer {
            return "Checking the private shelf"
        }

        switch serverStatus {
        case .loading:
            return "Checking the private shelf"
        case .online:
            return "Tailnet online, library ready"
        case .offline:
            return "Private shelf unreachable"
        }
    }

    var lastUpdatedText: String {
        if isReconnecting {
            return "Reconnecting"
        }
        if isRefreshing {
            return "Refreshing"
        }
        guard let lastUpdated else { return "Not yet" }
        return lastUpdated.formatted(date: .omitted, time: .shortened)
    }

    var serverStatusText: String {
        if isReconnecting {
            return "Reconnecting"
        }
        return isCheckingUnknownServer ? "Checking" : serverStatus.label
    }

    var isCheckingUnknownServer: Bool {
        (isRefreshing || isReconnecting) && serverStatus != .online
    }
}

private enum HomeServerStatus: Equatable {
    case loading
    case online
    case offline

    var label: String {
        switch self {
        case .loading:
            return "Checking"
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        }
    }
}

/// Static dot-grid texture for the server panel — a quiet nod to rack/console
/// UIs. Drawn once per layout; no animation, no hit testing.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 19
            var y: CGFloat = 8
            while y < size.height {
                var x: CGFloat = 8
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)),
                        with: .color(.white.opacity(0.045))
                    )
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// Decorative flowing lines for the downloader card's trailing space — pure
/// ornament (not data), kept faint so the count stays the focal point.
private struct WaveLines: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            for index in 0..<5 {
                var path = Path()
                let y = size.height * 0.46 + CGFloat(index) * 5
                path.move(to: CGPoint(x: 0, y: y))
                path.addCurve(
                    to: CGPoint(x: size.width, y: y + CGFloat(index % 2 == 0 ? -12 : 8)),
                    control1: CGPoint(x: size.width * 0.35, y: y + 18),
                    control2: CGPoint(x: size.width * 0.62, y: y - 22)
                )
                context.stroke(path, with: .color(tint), lineWidth: 0.8)
            }
        }
    }
}

#Preview {
    HomeView()
}
