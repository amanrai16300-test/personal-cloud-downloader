import Foundation
import SwiftUI

/// CloudBox Home: a private-cloud dashboard with one telemetry panel, an
/// asymmetric metrics bento, and a single action row. Visual language is
/// deliberately restrained — deep navy surfaces, hairline strokes, one blue
/// accent, monospaced telemetry — so it reads handcrafted rather than
/// template-like. All data, refresh, and navigation behavior is unchanged.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    brandHeader
                    serverPanel
                    metricsBento
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

                Text("Oracle · Tokyo")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mutedText.opacity(0.85))
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

        async let health = fetchHealth(foregroundReconnect: foregroundReconnect)
        async let torrents = fetchJSONArrayCount(path: "/api/torrents")
        async let completed = fetchJSONArrayCount(path: "/api/completed-files")

        let isHealthy = await health
        let torrentCount = await torrents
        let completedFileCount = await completed

        let nextState = HomeDashboardState(
            serverStatus: isHealthy ? .online : .offline,
            torrentCount: torrentCount,
            completedFileCount: completedFileCount,
            lastUpdated: Date(),
            isRefreshing: false,
            isReconnecting: false,
            hasLoaded: true
        )

        await MainActor.run {
            guard generation == refreshGeneration else { return }
            dashboard.isReconnecting = false
            dashboard = nextState
        }
    }

    private func fetchHealth(foregroundReconnect: Bool) async -> Bool {
        if foregroundReconnect {
            return await fetchHealthWithRetries()
        }
        return await fetchHealth()
    }

    private func fetchHealthWithRetries() async -> Bool {
        for attempt in 1...3 {
            if await fetchHealth() {
                return true
            }
            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                return false
            }
        }
        return false
    }

    private func fetchHealth() async -> Bool {
        guard let url = URL(string: "\(backendBaseURL)/api/health") else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func fetchJSONArrayCount(path: String) async -> Int? {
        guard let url = URL(string: "\(backendBaseURL)\(path)") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let json = try JSONSerialization.jsonObject(with: data)
            if let array = json as? [Any] {
                return array.count
            }
            if let dictionary = json as? [String: Any] {
                if let files = dictionary["files"] as? [Any] {
                    return files.count
                }
                if let torrents = dictionary["torrents"] as? [Any] {
                    return torrents.count
                }
                if let items = dictionary["items"] as? [Any] {
                    return items.count
                }
            }
            return nil
        } catch {
            return nil
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
        return torrentCount == 1 ? "Torrent tracked" : "Torrents tracked"
    }

    var completedFilesText: String {
        guard let completedFileCount else { return "Offline" }
        return "\(completedFileCount)"
    }

    var filesIndexText: String {
        completedFileCount == nil ? "Offline" : "Indexed"
    }

    var filesIndexDetail: String {
        guard let completedFileCount else { return "No connection" }
        return completedFileCount == 1 ? "1 completed item" : "\(completedFileCount) completed items"
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
