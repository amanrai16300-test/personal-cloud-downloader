import Foundation
import SwiftUI

struct HomeView: View {
    private let serverIP = "100.92.146.101"
    private let backendBaseURL = CompletedFilesAPI.baseURL
    private let refreshInterval: UInt64 = 12_000_000_000

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
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
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
                    startRefreshLoop()
                } else {
                    stopRefreshLoop()
                }
            }
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CloudBox")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(dashboard.headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)

                Spacer(minLength: 16)

                Image(systemName: serverStatusIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(serverStatusColor)
                    .frame(width: 42, height: 42)
                    .background(serverStatusColor.opacity(0.13), in: Circle())
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.caption.weight(.semibold))
                Text("Tailscale private")
                    .font(.caption.weight(.medium))
                Text(serverIP)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.secondarySystemGroupedBackground),
                            Color.accentColor.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
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
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dashboardGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
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
            HStack {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
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
    }

    private func actionCardContent(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var privateCloudNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            Text("Private CloudBox access stays behind Tailscale. Offline values mean the phone cannot reach the server right now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
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
        refreshTask?.cancel()
        refreshGeneration += 1
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

    private func refreshDashboard() async {
        let generation = await MainActor.run {
            refreshGeneration += 1
            dashboard.isRefreshing = true
            if !dashboard.hasLoaded {
                dashboard.serverStatus = .loading
            }
            return refreshGeneration
        }

        async let health = fetchHealth()
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
            hasLoaded: true
        )

        await MainActor.run {
            guard generation == refreshGeneration else { return }
            dashboard = nextState
        }
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

private struct HomeDashboardState {
    var serverStatus: HomeServerStatus = .loading
    var torrentCount: Int?
    var completedFileCount: Int?
    var lastUpdated: Date?
    var isRefreshing = false
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
        if isRefreshing {
            return "Refreshing"
        }
        guard let lastUpdated else { return "Not yet" }
        return lastUpdated.formatted(date: .omitted, time: .shortened)
    }

    var serverStatusText: String {
        isCheckingUnknownServer ? "Checking" : serverStatus.label
    }

    var isCheckingUnknownServer: Bool {
        isRefreshing && serverStatus != .online
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

#Preview {
    HomeView()
}
