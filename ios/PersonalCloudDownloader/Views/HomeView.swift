import Foundation
import SwiftUI

struct HomeView: View {
    private let serverIP = "100.95.39.107"
    private let backendBaseURL = CompletedFilesAPI.baseURL
    private let refreshInterval: UInt64 = 12_000_000_000
    private let screenBackground = Color(red: 0.015, green: 0.035, blue: 0.075)
    private let cardBackground = Color(red: 0.025, green: 0.075, blue: 0.155)
    private let cardStroke = Color(red: 0.16, green: 0.39, blue: 0.82)
    private let mutedText = Color(red: 0.58, green: 0.66, blue: 0.80)
    private let premiumBlue = Color(red: 0.28, green: 0.58, blue: 1.0)

    @Environment(\.scenePhase) private var scenePhase
    @State private var dashboard = HomeDashboardState()
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroHeader
                    statusStrip
                    dashboardGrid
                    tailscaleAction
                    privateCloudNote
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var homeBackground: some View {
        ZStack {
            screenBackground.ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.13, blue: 0.28).opacity(0.95),
                    screenBackground,
                    Color(red: 0.0, green: 0.015, blue: 0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.blue.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 300
            )
            .ignoresSafeArea()
        }
    }

    private var heroHeader: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Private media shelf")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(premiumBlue)
                        .textCase(.uppercase)
                        .tracking(1.2)

                    Text("CloudBox")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(dashboard.headerSubtitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(mutedText)
                        .lineLimit(2)

                    serverPill

                    heroStatsRow
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                cloudBoxIllustration
                    .frame(width: 126, height: 124)
                    .opacity(0.95)
            }
            .padding(24)

            Image(systemName: serverStatusIcon)
                .font(.title2.weight(.bold))
                .foregroundStyle(serverStatusColor)
                .frame(width: 52, height: 52)
                .background(serverStatusColor.opacity(0.20), in: Circle())
                .overlay(Circle().stroke(serverStatusColor.opacity(0.9), lineWidth: 1.5))
                .shadow(color: serverStatusColor.opacity(0.35), radius: 14)
                .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.24, blue: 0.52),
                            Color(red: 0.015, green: 0.045, blue: 0.11),
                            Color(red: 0.0, green: 0.02, blue: 0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.86), Color.white.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.25
                )
        }
        .shadow(color: premiumBlue.opacity(0.30), radius: 30, y: 18)
    }

    private var heroStatsRow: some View {
        HStack(spacing: 10) {
            heroStat(title: "Server", value: dashboard.serverStatusText, tint: serverStatusColor)
            heroStat(title: "Updated", value: dashboard.lastUpdatedText, tint: premiumBlue)
        }
    }

    private func heroStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(mutedText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minWidth: 92, alignment: .leading)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.34), lineWidth: 1)
        }
    }

    private var serverPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.caption.weight(.semibold))
            Text("Tailscale private")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white)
            Text(serverIP)
                .font(.caption.monospacedDigit())
                .foregroundStyle(mutedText)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.blue.opacity(0.22), in: Capsule())
        .overlay(Capsule().stroke(Color.blue.opacity(0.25), lineWidth: 1))
    }

    private var cloudBoxIllustration: some View {
        ZStack {
            ForEach(0..<4) { index in
                Circle()
                    .stroke(Color.blue.opacity(0.08), lineWidth: 1)
                    .frame(width: CGFloat(76 + index * 24), height: CGFloat(76 + index * 24))
            }

            Image(systemName: "server.rack")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.35, green: 0.67, blue: 1.0), Color(red: 0.04, green: 0.16, blue: 0.34)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.blue.opacity(0.35), radius: 10, y: 6)
                .offset(x: -12, y: -8)

            Image(systemName: "cloud.fill")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.13, green: 0.42, blue: 0.95), Color(red: 0.02, green: 0.10, blue: 0.24)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.blue.opacity(0.45), radius: 12, y: 8)
                .offset(x: 18, y: 26)
        }
    }

    private var statusStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
            statusPill(
                icon: serverStatusIcon,
                title: "Server",
                value: dashboard.serverStatusText,
                tint: serverStatusColor
            )

            statusPill(
                icon: dashboard.isRefreshing ? "arrow.triangle.2.circlepath" : "clock",
                title: "Updated",
                value: dashboard.lastUpdatedText,
                tint: .secondary
            )
        }
    }

    private func statusPill(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.18), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.32), lineWidth: 1))
                .shadow(color: tint.opacity(0.22), radius: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(mutedText)
                Text(value)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.24), cardBackground.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.50), lineWidth: 1.25)
        }
        .shadow(color: tint.opacity(0.16), radius: 16, y: 9)
    }

    private var dashboardGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
            dashboardCard(
                icon: "arrow.down.circle.fill",
                title: "Downloader",
                value: dashboard.torrentCountText,
                detail: dashboard.activeTorrentText,
                tint: .blue
            )

            dashboardCard(
                icon: "play.rectangle.fill",
                title: "Videos",
                value: dashboard.completedFilesText,
                detail: "Completed files",
                tint: .purple
            )

            dashboardCard(
                icon: "externaldrive.fill",
                title: "Files",
                value: dashboard.filesIndexText,
                detail: dashboard.filesIndexDetail,
                tint: .teal
            )

        }
    }

    private func dashboardCard(icon: String, title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .shadow(color: tint.opacity(0.32), radius: 12, y: 7)

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(value)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.18), cardBackground.opacity(0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .bottom) {
                    WaveLines(tint: tint.opacity(0.28))
                        .frame(height: 42)
                        .offset(y: 10)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1)
        }
    }

    private var tailscaleAction: some View {
        Link(destination: URL(string: "tailscale://")!) {
            actionCardContent(
                icon: "network",
                title: "Open Tailscale",
                subtitle: "Private connection / VPN route",
                tint: .orange
            )
        }
        .buttonStyle(HomePressStyle())
    }

    private func actionCardContent(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "globe")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color(red: 0.62, green: 0.80, blue: 1.0))
                    .frame(width: 62, height: 62)
                    .background(Color.blue.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(Color.blue.opacity(0.42), lineWidth: 1))

                Image(systemName: "lock.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(Color.blue, in: Circle())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .layoutPriority(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color(red: 0.70, green: 0.83, blue: 1.0))
                .frame(width: 52, height: 52)
                .background(Color.blue.opacity(0.13), in: Circle())
                .overlay(Circle().stroke(Color.blue.opacity(0.72), lineWidth: 1.5))
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.20), cardBackground.opacity(0.90)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.blue.opacity(0.58), lineWidth: 1.25)
        }
        .shadow(color: Color.blue.opacity(0.18), radius: 18, y: 10)
    }

    private var privateCloudNote: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(mutedText)
                .frame(width: 54)
            Text("Private CloudBox access stays behind Tailscale. Offline values mean the phone cannot reach the server right now.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground.opacity(0.68), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardStroke.opacity(0.38), lineWidth: 1)
        }
    }

    private var serverStatusIcon: String {
        if dashboard.isCheckingUnknownServer {
            return "arrow.triangle.2.circlepath"
        }

        switch dashboard.serverStatus {
        case .loading:
            return "arrow.triangle.2.circlepath"
        case .online:
            return "checkmark.circle.fill"
        case .offline:
            return "xmark.circle.fill"
        }
    }

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
