import Foundation
import SwiftUI

/// CloudBox Home: a private-cloud dashboard. The layout follows the locked
/// reference design — a greeting + wordmark header, a connection panel with a
/// device→cloud→server link diagram, a Continue Watching backdrop card, a
/// four-up stat strip, a Network Activity + System Status pair, and a Recently
/// Added poster strip.
///
/// Data layer (unchanged): one aggregated `GET /api/home-dashboard` request
/// feeds server, library, downloads, network, Continue Watching, and Recently
/// Added. Request round-trip time is measured client-side for the latency
/// readout. Media taps reuse the existing VideosView → PlayerView flow: the
/// home item is matched to the real `CompletedFile` (for the correct stream URL
/// + AVPlayer/VLC routing) and its saved-resume position is seeded before
/// pushing the player.
struct HomeView: View {
    /// Top-level tab selection, injected by RootTabView so the "View Network"
    /// shortcut can switch to the existing Network tab. Optional so the view
    /// still previews standalone.
    var selectedTab: Binding<RootTabView.Tab>?
    var reconnectCycle: Int = 0
    var reconnectRefreshToken: Int = 0

    private let backendBaseURL = CompletedFilesAPI.baseURL
    private let refreshInterval: UInt64 = 12_000_000_000

    // MARK: Palette — semantic tokens, used consistently across the screen.
    private let screenBackground = Color(red: 0.018, green: 0.030, blue: 0.058)
    private let surface = Color(red: 0.032, green: 0.052, blue: 0.092)
    private let surfaceRaised = Color(red: 0.045, green: 0.070, blue: 0.125)
    private let hairline = Color.white.opacity(0.06)
    private let mutedText = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.42, green: 0.45, blue: 0.98)
    private let videosViolet = Color(red: 0.55, green: 0.50, blue: 1.0)
    private let filesGreen = Color(red: 0.30, green: 0.80, blue: 0.52)
    private let downloadAmber = Color(red: 1.0, green: 0.58, blue: 0.18)
    private let storageBlue = Color(red: 0.34, green: 0.62, blue: 1.0)
    private let onlineGreen = Color(red: 0.30, green: 0.82, blue: 0.46)

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var brandTitleSize: CGFloat = 42
    @ScaledMetric(relativeTo: .body) private var continueWatchingCardHeight: CGFloat = 184
    @State private var dashboard = HomeDashboardState()
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = 0
    /// When the current refresh loop was started — dedupes overlapping
    /// onAppear/foreground/reconnect-token triggers.
    @State private var lastRefreshStart: Date?
    /// Whether Home is the visible tab; foreground restarts only apply then.
    @State private var isVisible = false
    /// Pushed when a media card is tapped — the matched real `CompletedFile`,
    /// which drives PlayerView's stream URL and AVPlayer/VLC routing.
    @State private var selectedVideo: CompletedFile?
    @State private var completedVideosCache: [CompletedFile]?
    @State private var lastProcessedRecentlyAddedSet: Set<String>?
    @State private var isCardMatchInFlight = false
    @State private var showMediaUnavailableAlert = false

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
                VStack(alignment: .leading, spacing: 22) {
                    brandHeader
                    connectionPanel
                    continueWatchingSection
                    statStrip
                    statusRow
                    recentlyAddedSection
                    tailscaleAction
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                // Clearance so the floating tab bar never covers the last row.
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity, alignment: .leading)
                // One animation driver for the whole dashboard: counts and
                // status text settle with a short ease whenever fresh data
                // lands (contentTransition handles the digit morph).
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: dashboard.lastUpdated)
            }
            .background(homeBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            // A tapped media card pushes the existing fullscreen player, exactly
            // as the Videos list does (same CompletedFile destination + flow).
            // Programmatic push via a binding (iOS 16-compatible: no
            // `navigationDestination(item:)`, which is iOS 17+).
            .navigationDestination(isPresented: playerPresented) {
                if let video = selectedVideo {
                    PlayerView(video: video, startsFullscreen: true)
                }
            }
            // FolderVideosView rows navigate with CompletedFile values. Register
            // the same destination as VideosView so Home-launched series episodes
            // open the existing player flow.
            .navigationDestination(for: CompletedFile.self) { video in
                PlayerView(video: video, startsFullscreen: true)
            }
            // A tapped grouped-series card pushes the exact same folder/episode
            // picker the Videos tab uses (FolderVideosView), where the user
            // selects an episode. No second episode list is built in Home.
            .navigationDestination(for: VideoFolder.self) { folder in
                FolderVideosView(folder: folder, progressByPath: [:])
            }
            .refreshable {
                await refreshDashboard(forceLibraryReconciliation: true)
            }
            .onAppear {
                isVisible = true
                loadCachedDashboardIfNeeded()
                startRefreshLoop()
            }
            .onDisappear {
                isVisible = false
                stopRefreshLoop()
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    stopRefreshLoop()
                }
            }
            .onChange(of: reconnectCycle) { _ in
                // Foreground: restart immediately — the dashboard fetch itself
                // is Home's health check, so it never waits on the /api/health
                // probe gate. Hidden tabs stay stopped (onDisappear already did).
                if isVisible {
                    startRefreshLoop()
                }
            }
            .onChange(of: reconnectRefreshToken) { _ in
                startRefreshLoop()
            }
            .alert(
                "Video unavailable",
                isPresented: $showMediaUnavailableAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Refresh Home or check the connection.")
            }
        }
    }

    // MARK: Background — subtle deep navy→black, one faint top bloom, no glow.

    private var homeBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.022, green: 0.038, blue: 0.072),
                    screenBackground,
                    Color(red: 0.006, green: 0.012, blue: 0.028)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Brand header — greeting + wordmark + subtitle.

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dashboard.greetingText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mutedText)

            Text("CloudBox")
                .font(.system(size: brandTitleSize, weight: .heavy))
                .foregroundStyle(Color.white)
                .lineLimit(2)

            Text("Your private cloud. Always connected.")
                .font(.subheadline)
                .foregroundStyle(mutedText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Connection panel — status + link diagram centerpiece.

    private var connectionPanel: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    StatusOrb(color: connectionDotColor, animates: !reduceMotion)
                    Text(dashboard.connectionLabel)
                        .font(.caption.weight(.bold))
                        .tracking(dynamicTypeSize.isAccessibilitySize ? 0 : 1.4)
                        .foregroundStyle(connectionDotColor)
                        .contentTransition(.opacity)
                        .lineLimit(2)
                }
                .padding(.bottom, 8)

                Text("Oracle • Tokyo")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .padding(.bottom, 6)

                (
                    Text(dashboard.latencyValueText)
                        .foregroundColor(onlineGreen)
                    + Text(" latency")
                        .foregroundColor(mutedText)
                )
                .font(.subheadline.weight(.medium))
                .contentTransition(.opacity)
                .padding(.bottom, cachedDataAgeText == nil ? 14 : 5)

                if let cachedDataAgeText {
                    Text(cachedDataAgeText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(mutedText)
                        .lineLimit(2)
                        .padding(.bottom, 14)
                }

                // Switches to the existing Network bottom tab.
                Button {
                    selectedTab?.wrappedValue = .network
                } label: {
                    HStack(spacing: 5) {
                        Text("View Network")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(mutedText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(surfaceRaised, in: Capsule())
                    .overlay { Capsule().stroke(hairline, lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .buttonStyle(HomePressStyle())
                .accessibilityLabel("View Network")
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            ConnectionDiagram(linkActive: dashboard.serverStatus == .online,
                              accent: premiumBlue,
                              link: onlineGreen)
                .frame(width: 132, height: 132)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(connectionPanelSurface)
    }

    private var cachedDataAgeText: String? {
        guard dashboard.isShowingCachedData,
              let lastUpdated = dashboard.lastUpdated else {
            return nil
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last updated \(formatter.localizedString(for: lastUpdated, relativeTo: Date()))"
    }

    /// Connection panel only — keeps the dotted "global" texture. Tighter radius
    /// and a hairline border so it reads as a restrained card, not a bubble.
    private var connectionPanelSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surface)
            DotWorld()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(hairline, lineWidth: 1)
        }
    }

    /// Flat dark surface shared by every other section — no texture, no glow.
    /// `radius` lets sections vary their corner softness slightly so the page
    /// doesn't read as identical stacked rectangles.
    private func panelSurface(radius: CGFloat = 14) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(surface)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }

    // MARK: Continue Watching — wide backdrop resume card.

    @ViewBuilder
    private var continueWatchingSection: some View {
        if let item = dashboard.continueWatching {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Continue Watching", trailing: "See all")

                Button {
                    openMedia(item)
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        // Large cinematic backdrop fills the whole card. Rendered
                        // in an overlay of a fixed-footprint base so the artwork's
                        // aspect ratio can never widen the card (scaledToFill
                        // reports its cover size; .clipped() hides pixels but not
                        // layout width).
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: continueWatchingCardHeight)
                            .overlay {
                                mediaArtwork(item, wide: true)
                            }
                            .clipped()

                        // Dark scrim — stronger left/bottom — so overlaid text and
                        // progress stay readable over any artwork.
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.78),
                                Color.black.opacity(0.30),
                                Color.black.opacity(0.05)
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )

                        // Play affordance, top-left, integrated over the artwork.
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay { Circle().stroke(Color.white.opacity(0.45), lineWidth: 1) }
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        // Title block + integrated progress, bottom-left.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            if let subtitle = item.subtitleText {
                                Text(subtitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.70, green: 0.80, blue: 1.0))
                                    .lineLimit(2)
                            }

                            Text(item.remainingText)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.white.opacity(0.78))
                                .lineLimit(2)
                                .padding(.bottom, 4)

                            mediaProgressBar(item.progressFraction)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: continueWatchingCardHeight)
                    .background(surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(hairline, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(HomePressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(continueWatchingAccessibilityLabel(for: item))
                .accessibilityValue(item.watchProgressAccessibilityValue)
            }
        }
    }

    // MARK: Stat strip — four metrics in one divided card.

    private var statStrip: some View {
        HStack(spacing: 0) {
            statColumn(
                icon: "play.circle",
                tint: videosViolet,
                value: dashboard.completedFilesText,
                unit: nil,
                title: "Videos",
                detail: "In library"
            )
            statDivider
            statColumn(
                icon: "folder",
                tint: filesGreen,
                value: dashboard.filesIndexText,
                unit: nil,
                title: dashboard.filesIndexDetail,
                detail: "Files"
            )
            statDivider
            statColumn(
                icon: "arrow.down.circle",
                tint: downloadAmber,
                value: dashboard.torrentCountText,
                unit: nil,
                title: "Active",
                detail: "Downloads"
            )
            statDivider
            statColumn(
                icon: "cylinder.split.1x2",
                tint: storageBlue,
                value: dashboard.storageUsedValue,
                unit: dashboard.storageUsedUnit,
                title: dashboard.storageTotalText,
                detail: "Storage used"
            )
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(panelSurface(radius: 12))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(width: 1, height: 70)
    }

    private func statColumn(
        icon: String,
        tint: Color,
        value: String,
        unit: String?,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 24)
                .padding(.bottom, 2)

            (
                Text(value)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                + Text(unit.map { " \($0)" } ?? "")
                    .font(.caption.weight(.bold))
                    .foregroundColor(mutedText)
            )
            .monospacedDigit()
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(mutedText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    // MARK: Network Activity + System Status pair.

    private var statusRow: some View {
        HStack(spacing: 12) {
            networkActivityCard
            systemStatusCard
        }
    }

    private var networkActivityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Network Activity")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.bottom, 12)

            EqualizerBars(tint: premiumBlue, animates: !reduceMotion)
                .frame(height: 48)
                .padding(.bottom, 12)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(dashboard.networkSpeedText)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(premiumBlue)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(2)
                Text("Current Speed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mutedText)
                    .lineLimit(2)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(panelSurface(radius: 14))
    }

    private var systemStatusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("System Status")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.bottom, 16)

            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(dashboard.serverStatus == .online ? onlineGreen : mutedText)
                Text(dashboard.systemStatusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            .padding(.bottom, 6)

            Text(dashboard.uptimeText)
                .font(.caption.weight(.medium))
                .foregroundStyle(mutedText)
                .padding(.leading, 27)
                .contentTransition(.opacity)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(panelSurface(radius: 14))
    }

    // MARK: Tailscale action — the screen's single tappable utility row.

    /// Opens the Tailscale app via its custom scheme (unchanged behavior).
    /// Styled to match the new dashboard surfaces; sits below the content so the
    /// top of the screen stays faithful to the reference layout.
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
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)

                    Text("Private connection / VPN route")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(mutedText)
                        .lineLimit(2)
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
            .background(panelSurface(radius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel("Open Tailscale")
    }

    // MARK: Recently Added — horizontal poster strip, hidden when empty.

    @ViewBuilder
    private var recentlyAddedSection: some View {
        if !dashboard.recentlyAddedEntries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Recently Added", trailing: "View all")

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
                                        title: entry.posterTitle,
                                        episodeCount: nil
                                    )
                                }
                                .buttonStyle(HomePressStyle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(entry.posterTitle)
                                .accessibilityValue(
                                    recentlyAddedAccessibilityValue(for: item, episodeCount: nil)
                                )

                            case .series(let folder, let item):
                                // Tapping opens the existing folder/episode
                                // picker (same screen as the Videos tab).
                                NavigationLink(value: folder) {
                                    recentlyAddedCard(
                                        item: item,
                                        title: entry.posterTitle,
                                        episodeCount: folder.videos.count
                                    )
                                }
                                .buttonStyle(HomePressStyle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(entry.posterTitle)
                                .accessibilityValue(
                                    recentlyAddedAccessibilityValue(
                                        for: item,
                                        episodeCount: folder.videos.count
                                    )
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    /// One Recently Added poster card. The title (movie name, series episode tag,
    /// or year) sits over the bottom of the artwork, with a progress hairline
    /// beneath — matching the reference strip. `item` supplies the artwork
    /// (poster_url → local_thumbnail_url → placeholder).
    private func recentlyAddedCard(item: HomeMediaItem, title: String, episodeCount: Int?) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                mediaArtwork(item, wide: false)
                    .frame(width: 132, height: 188)
                    .clipped()

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 90)
                .frame(maxHeight: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if let episodeCount {
                        Text(episodeCount == 1 ? "1 ep" : "\(episodeCount) eps")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.75))
                    } else if let year = item.yearText {
                        Text(year)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
            .frame(width: 132, height: 188)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }

            mediaProgressBar(item.progressFraction)
                .padding(.horizontal, 4)
                .padding(.top, 7)
        }
        .frame(width: 132)
    }

    private func sectionHeader(_ text: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button {
                selectedTab?.wrappedValue = .videos
            } label: {
                Text(trailing)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(premiumBlue)
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(trailing) videos")
        }
    }

    /// Artwork for a media card. TMDB poster/backdrop are preferred when present
    /// (backdrop for the wide Continue Watching card, poster for portrait
    /// Recently Added), falling back to the local thumbnail, then a placeholder.
    /// Visual only — never used for playback identity.
    @ViewBuilder
    private func mediaArtwork(_ item: HomeMediaItem, wide: Bool) -> some View {
        let url = wide ? item.wideArtworkURL : item.portraitArtworkURL
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
    }

    private var mediaArtworkPlaceholder: some View {
        Rectangle()
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
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(premiumBlue)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }

    private func continueWatchingAccessibilityLabel(for item: HomeMediaItem) -> String {
        [item.title, item.subtitleText, "Watch progress"]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func recentlyAddedAccessibilityValue(
        for item: HomeMediaItem,
        episodeCount: Int?
    ) -> String {
        var details: [String] = []
        if let episodeCount {
            details.append(episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes")
        } else if let year = item.yearText {
            details.append(year)
        }
        let percent = Int((item.progressFraction * 100).rounded())
        if percent > 0 {
            details.append("\(percent) percent watched")
        }
        return details.isEmpty ? "Recently added" : details.joined(separator: ", ")
    }

    // MARK: Status mapping (unchanged behavior)

    private var connectionDotColor: Color {
        if dashboard.isCheckingUnknownServer { return mutedText }
        switch dashboard.serverStatus {
        case .loading: return mutedText
        case .online: return onlineGreen
        case .offline: return .red
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
        if let cachedVideos = completedVideosCache,
           let matched = matchVideo(for: item, in: cachedVideos) {
            seedResume(for: matched, item: item)
            selectedVideo = matched
            return
        }

        guard !isCardMatchInFlight else { return }
        isCardMatchInFlight = true
        let generation = refreshGeneration

        Task {
            let fetchedVideos = try? await CompletedFilesAPI.fetchVideos()
            await MainActor.run {
                defer { isCardMatchInFlight = false }
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                guard let fetchedVideos else {
                    showMediaUnavailableAlert = true
                    return
                }

                completedVideosCache = fetchedVideos
                guard let matched = matchVideo(for: item, in: fetchedVideos) else {
                    showMediaUnavailableAlert = true
                    return
                }
                seedResume(for: matched, item: item)
                selectedVideo = matched
            }
        }
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

    // MARK: Refresh loop

    private func startRefreshLoop() {
        // Dedupe: onAppear, foreground reconnect, and the reconnect token can
        // all fire within moments of each other. If a loop is already running
        // and its refresh started seconds ago, keep it instead of restarting
        // the whole fetch chain.
        if refreshTask != nil,
           let last = lastRefreshStart,
           Date().timeIntervalSince(last) < 3 {
            return
        }
        refreshTask?.cancel()
        refreshGeneration += 1
        lastRefreshStart = Date()
        refreshTask = Task {
            await refreshDashboard()

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

    private func refreshDashboard(forceLibraryReconciliation: Bool = false) async {
        let generation = await MainActor.run {
            refreshGeneration += 1
            dashboard.isRefreshing = true
            if !dashboard.hasLoaded {
                dashboard.serverStatus = .loading
            }
            return refreshGeneration
        }

        let result = await fetchDashboard()

        // Phase 1: apply the dashboard as soon as it arrives — first paint
        // never waits for the library fetch. The current Recently Added
        // entries stay on screen until the regrouped set lands.
        await MainActor.run {
            guard generation == refreshGeneration else { return }
            dashboard = makeState(from: result, recentlyAddedEntries: dashboard.recentlyAddedEntries)
        }

        guard let response = result?.response else { return }
        let items = response.recentlyAdded ?? []
        let recentlyAddedSet = recentlyAddedIdentitySet(for: items)
        let shouldReconcileLibrary = await MainActor.run {
            guard generation == refreshGeneration else { return false }
            return forceLibraryReconciliation
                || completedVideosCache == nil
                || lastProcessedRecentlyAddedSet != recentlyAddedSet
        }
        guard shouldReconcileLibrary else { return }

        // Phase 2: resolve Recently Added grouping off the main actor: match
        // each item to its real CompletedFile and group by torrent folder (the
        // same identity VideosView uses). TV episodes sharing a folder collapse
        // into one series entry; everything else stays an individual (movie)
        // card. Guarded by the same generation so a stale grouping can never
        // overwrite a newer refresh.
        let fetchedVideos = try? await CompletedFilesAPI.fetchVideos()
        let cachedVideos = await MainActor.run { completedVideosCache }
        let videosForGrouping = fetchedVideos ?? cachedVideos
        let entries: [RecentlyAddedEntry]
        if let videosForGrouping {
            entries = makeRecentlyAddedEntries(from: items, videos: videosForGrouping)
        } else {
            let movies = items.enumerated().map { index, item in
                RecentlyAddedEntry(kind: .movie(item), sortDate: backendOrderDate(at: index))
            }
            entries = Array(movies.prefix(Self.recentlyAddedDisplayLimit))
        }

        await MainActor.run {
            guard generation == refreshGeneration else { return }
            if let fetchedVideos {
                completedVideosCache = fetchedVideos
                lastProcessedRecentlyAddedSet = recentlyAddedSet
            }
            dashboard.recentlyAddedEntries = entries
        }
    }

    // MARK: Cache-first launch

    private static let dashboardCacheKey = "homeDashboardCacheV1"
    private static let dashboardCacheTimestampKey = "homeDashboardCacheTimestampV1"

    /// Render the last-good dashboard snapshot immediately on a cold launch,
    /// before any network round-trip. Connection status and latency always come
    /// from a live fetch, so they stay in the "checking" state; Recently Added
    /// shows ungrouped fallback cards until the live refresh regroups series.
    private func loadCachedDashboardIfNeeded() {
        guard !dashboard.hasLoaded,
              let data = UserDefaults.standard.data(forKey: Self.dashboardCacheKey),
              let cached = try? JSONDecoder().decode(HomeDashboardResponse.self, from: data)
        else { return }

        let cachedAt = UserDefaults.standard.object(forKey: Self.dashboardCacheTimestampKey) as? Date
        var state = makeState(
            from: DashboardFetch(response: cached, latencyMs: 0, fetchedAt: cachedAt),
            recentlyAddedEntries: (cached.recentlyAdded ?? [])
                .prefix(Self.recentlyAddedDisplayLimit)
                .enumerated()
                .map { RecentlyAddedEntry(kind: .movie($0.element), sortDate: backendOrderDate(at: $0.offset)) }
        )
        state.serverStatus = .loading
        state.latencyMs = nil
        state.isRefreshing = true
        state.isShowingCachedData = true
        dashboard = state
    }

    /// Build the view state from a fetch outcome. A failed fetch marks the
    /// retained dashboard offline; a successful response replaces its data.
    private func makeState(from result: DashboardFetch?, recentlyAddedEntries: [RecentlyAddedEntry]) -> HomeDashboardState {
        guard let result else {
            var cached = dashboard
            cached.serverStatus = .offline
            cached.isRefreshing = false
            cached.isReconnecting = false
            cached.isShowingCachedData = cached.lastUpdated != nil
            cached.hasLoaded = true
            return cached
        }

        let response = result.response
        return HomeDashboardState(
            serverStatus: (response.server?.online ?? true) ? .online : .offline,
            uptimeSeconds: response.server?.uptimeSeconds,
            torrentCount: response.downloads?.activeCount,
            completedFileCount: response.library?.videoCount,
            indexedFileCount: response.library?.fileCount,
            storageUsedBytes: response.library?.storageUsedBytes,
            storageTotalBytes: response.library?.storageTotalBytes,
            networkBytesPerSecond: response.network?.totalBytesPerSecond,
            latencyMs: result.latencyMs,
            continueWatching: response.continueWatching,
            recentlyAdded: response.recentlyAdded ?? [],
            recentlyAddedEntries: recentlyAddedEntries,
            lastUpdated: result.fetchedAt,
            isRefreshing: false,
            isReconnecting: false,
            isShowingCachedData: false,
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
    private func makeRecentlyAddedEntries(
        from items: [HomeMediaItem],
        videos: [CompletedFile]
    ) -> [RecentlyAddedEntry] {
        guard !items.isEmpty else { return [] }

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

        // The backend over-fetches raw videos so episodes can be grouped; show
        // only the newest few unique cards (one per movie / per series).
        let ordered = entries.sorted { $0.sortDate > $1.sortDate }
        return Array(ordered.prefix(Self.recentlyAddedDisplayLimit))
    }

    /// Max unique Recently Added cards shown after series grouping.
    private static let recentlyAddedDisplayLimit = 8

    /// A synthetic descending timestamp that preserves the backend's newest-first
    /// Recently Added order when a real `modified_at` is unavailable (earlier
    /// index → more recent).
    private func backendOrderDate(at index: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: -Double(index))
    }

    /// Synchronous CompletedFile match against an already-fetched list.
    private func matchVideo(for item: HomeMediaItem, in videos: [CompletedFile]) -> CompletedFile? {
        let target = item.relativePath
        return videos.first { normalizePath($0.path) == normalizePath(target) || normalizePath($0.name) == normalizePath(target) }
    }

    private func recentlyAddedIdentitySet(for items: [HomeMediaItem]) -> Set<String> {
        Set(items.flatMap { item in
            [
                "id:\(item.videoId)",
                "path:\(normalizePath(item.relativePath))"
            ]
        })
    }

    /// One aggregated request. Measures the round-trip time client-side for the
    /// latency readout (the backend deliberately does not compute latency).
    private func fetchDashboard() async -> DashboardFetch? {
        guard let url = URL(string: "\(backendBaseURL)/api/home-dashboard") else { return nil }

        let start = DispatchTime.now()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 9
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(HomeDashboardResponse.self, from: data)
            let fetchedAt = Date()
            // Persist the raw (small, secret-free) payload as the last-good
            // snapshot for instant cold-launch rendering.
            UserDefaults.standard.set(data, forKey: Self.dashboardCacheKey)
            UserDefaults.standard.set(fetchedAt, forKey: Self.dashboardCacheTimestampKey)
            return DashboardFetch(
                response: decoded,
                latencyMs: Int(elapsedNs / 1_000_000),
                fetchedAt: fetchedAt
            )
        } catch {
            return nil
        }
    }
}

/// A successful dashboard fetch plus the measured client round-trip latency.
private struct DashboardFetch {
    let response: HomeDashboardResponse
    let latencyMs: Int
    let fetchedAt: Date?
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
        let storageUsedBytes: Int?
        let storageTotalBytes: Int?

        enum CodingKeys: String, CodingKey {
            case videoCount = "video_count"
            case fileCount = "file_count"
            case storageUsedBytes = "storage_used_bytes"
            case storageTotalBytes = "storage_total_bytes"
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

        /// Combined current throughput for the single "Current Speed" readout.
        var totalBytesPerSecond: Int? {
            guard rxBytesPerSecond != nil || txBytesPerSecond != nil else { return nil }
            return (rxBytesPerSecond ?? 0) + (txBytesPerSecond ?? 0)
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

    /// "32:15 remaining" style readout for the Continue Watching card, from the
    /// backend duration/position. Falls back to a progress percentage when the
    /// duration is unknown, and to a generic line when neither is available.
    var remainingText: String {
        let remaining = durationSeconds - positionSeconds
        if durationSeconds > 0, remaining > 0 {
            return "\(Self.clockText(remaining)) remaining"
        }
        if durationSeconds > 0 {
            return "Finished"
        }
        let percent = Int((progressFraction * 100).rounded())
        return percent > 0 ? "\(percent)% watched" : "Resume watching"
    }

    var watchProgressAccessibilityValue: String {
        let percent = Int((progressFraction * 100).rounded())
        guard durationSeconds > 0,
              positionSeconds >= 0,
              positionSeconds <= durationSeconds else {
            return percent > 0 ? "\(percent) percent" : "Resume watching"
        }
        return "\(percent) percent. \(Self.clockText(positionSeconds)) elapsed. \(remainingText)"
    }

    private static func clockText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
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

    /// Poster overlay title. Movies use their own title (which may already carry
    /// a year line beneath); series use the folder name. The year is shown
    /// separately beneath, taken straight from the dashboard payload.
    var posterTitle: String {
        switch kind {
        case .movie(let item): return item.title
        case .series(let folder, _): return folder.name
        }
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
        .frame(width: 14, height: 14)
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
    var uptimeSeconds: Int?
    var torrentCount: Int?
    var completedFileCount: Int?
    var indexedFileCount: Int?
    var storageUsedBytes: Int?
    var storageTotalBytes: Int?
    var networkBytesPerSecond: Int?
    var latencyMs: Int?
    var continueWatching: HomeMediaItem?
    var recentlyAdded: [HomeMediaItem] = []
    var recentlyAddedEntries: [RecentlyAddedEntry] = []
    var lastUpdated: Date?
    var isRefreshing = false
    var isReconnecting = false
    var isShowingCachedData = false
    var hasLoaded = false

    var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: part = "Good night"
        }
        return "\(part), Aman"
    }

    var connectionLabel: String {
        if isReconnecting { return "RECONNECTING" }
        if isCheckingUnknownServer { return "CHECKING" }
        switch serverStatus {
        case .loading: return "CHECKING"
        case .online: return "CONNECTED"
        case .offline: return "OFFLINE"
        }
    }

    var torrentCountText: String {
        guard let torrentCount else { return "—" }
        return "\(torrentCount)"
    }

    var completedFilesText: String {
        guard let completedFileCount else { return "—" }
        return "\(completedFileCount)"
    }

    var filesIndexText: String {
        indexedFileCount == nil ? "—" : "Indexed"
    }

    var filesIndexDetail: String {
        guard let indexedFileCount else { return "No data" }
        return indexedFileCount == 1 ? "1 item" : "\(indexedFileCount) items"
    }

    /// Numeric portion of the storage-used readout (e.g. "82"). The unit is shown
    /// separately so it can be set in a smaller weight, matching the reference.
    var storageUsedValue: String {
        guard let storageUsedBytes else { return "—" }
        return Self.byteValue(storageUsedBytes)
    }

    var storageUsedUnit: String? {
        guard let storageUsedBytes else { return nil }
        return Self.byteUnit(storageUsedBytes)
    }

    var storageTotalText: String {
        guard let storageTotalBytes else { return "Storage" }
        return "of \(Self.byteValue(storageTotalBytes)) \(Self.byteUnit(storageTotalBytes))"
    }

    var networkSpeedText: String {
        guard let networkBytesPerSecond else { return "—" }
        return Self.speedText(networkBytesPerSecond)
    }

    var latencyValueText: String {
        if isReconnecting || isRefreshing { return "— ms" }
        guard let latencyMs else { return "— ms" }
        return "\(latencyMs) ms"
    }

    var systemStatusText: String {
        switch serverStatus {
        case .loading: return "Checking systems"
        case .online: return "All systems operational"
        case .offline: return "Server unreachable"
        }
    }

    var uptimeText: String {
        guard serverStatus == .online, let uptimeSeconds, uptimeSeconds > 0 else {
            return "Uptime unavailable"
        }
        return "Uptime: \(Self.uptime(uptimeSeconds))"
    }

    var serverStatusText: String {
        if isReconnecting { return "Reconnecting" }
        return isCheckingUnknownServer ? "Checking" : serverStatus.label
    }

    var isCheckingUnknownServer: Bool {
        (isRefreshing || isReconnecting) && serverStatus != .online
    }

    // MARK: Formatting helpers

    /// Largest sensible binary unit value, no unit suffix (e.g. 88_000_000_000 → "82").
    private static func byteValue(_ bytes: Int) -> String {
        let (value, _) = byteParts(bytes)
        return value
    }

    private static func byteUnit(_ bytes: Int) -> String {
        let (_, unit) = byteParts(bytes)
        return unit
    }

    private static func byteParts(_ bytes: Int) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let rounded = value >= 100 || value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
        return (rounded, units[index])
    }

    private static func speedText(_ bytesPerSecond: Int) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSecond)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let rounded = value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return "\(rounded) \(units[index])"
    }

    private static func uptime(_ seconds: Int) -> String {
        let d = seconds / 86_400
        let h = (seconds % 86_400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

private enum HomeServerStatus: Equatable {
    case loading
    case online
    case offline

    var label: String {
        switch self {
        case .loading: return "Checking"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

/// Faint dotted world-map texture for the connection panel — a quiet nod to the
/// reference's globe backdrop. Drawn once per layout; no animation, no hit
/// testing. (Not a literal map — a regular dot field reading as "global".)
private struct DotWorld: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 13
            var y: CGFloat = 10
            while y < size.height {
                var x: CGFloat = 10
                while x < size.width {
                    // Bias density toward the right half so it reads as a panel
                    // ornament behind the diagram, not a full-bleed grid.
                    let opacity = x > size.width * 0.42 ? 0.05 : 0.02
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(.white.opacity(opacity))
                    )
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// The device → cloud → server link diagram. A phone chip on the left and a
/// server chip on the right are joined by a connector line to a glowing cloud
/// orb in the center. The connector tints green when the tailnet is online.
/// Pure ornament — labels included to match the reference.
private struct ConnectionDiagram: View {
    let linkActive: Bool
    let accent: Color
    let link: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h * 0.40
            let orbSize: CGFloat = 50
            // Inset the endpoints so their bounded labels stay inside the frame.
            let endInset = w * 0.18

            ZStack {
                // Connector: one straight horizontal line, end dot → end dot.
                Path { p in
                    p.move(to: CGPoint(x: endInset, y: midY))
                    p.addLine(to: CGPoint(x: w - endInset, y: midY))
                }
                .stroke(
                    (linkActive ? link : Color.white.opacity(0.18)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )

                // Left: this iPhone.
                endpointChip(systemName: "iphone", label: "This iPhone", maxWidth: endInset * 2 - 4)
                    .position(x: endInset, y: midY)

                // Right: CloudBox server.
                endpointChip(systemName: "server.rack", label: "CloudBox Server", maxWidth: endInset * 2 - 4)
                    .position(x: w - endInset, y: midY)

                // Center: glowing cloud orb.
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: orbSize + 16, height: orbSize + 16)
                        .blur(radius: 6)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [accent.opacity(0.55), Color(red: 0.05, green: 0.07, blue: 0.18)],
                                center: .center, startRadius: 2, endRadius: orbSize
                            )
                        )
                        .frame(width: orbSize, height: orbSize)
                        .overlay { Circle().stroke(accent.opacity(0.7), lineWidth: 1.5) }
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .position(x: w / 2, y: midY)
            }
        }
    }

    private func endpointChip(systemName: String, label: String, maxWidth: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.05), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.12), lineWidth: 1) }

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(width: maxWidth)
        }
    }
}

/// Decorative equalizer bars for the Network Activity card — pure ornament (not
/// real per-band data), kept restrained. Animates a gentle height shimmer unless
/// Reduce Motion is on.
private struct EqualizerBars: View {
    let tint: Color
    let animates: Bool

    @State private var phase: CGFloat = 0
    private let count = 34
    // Fixed pseudo-random base heights so the silhouette is stable across redraws.
    private let bases: [CGFloat] = (0..<34).map { i in
        let n = sin(Double(i) * 1.7) * 0.5 + cos(Double(i) * 0.6) * 0.5
        return CGFloat(0.35 + abs(n) * 0.6)
    }

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let wobble = animates ? (sin(phase + CGFloat(i) * 0.5) * 0.12) : 0
                    let h = min(1, max(0.12, bases[i] + wobble))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.45)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: geo.size.height * h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            guard animates else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    HomeView()
}
