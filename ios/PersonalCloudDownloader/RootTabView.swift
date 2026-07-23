import Foundation
import SwiftUI
import UIKit

struct RootTabView: View {
    /// The five top-level destinations, unchanged from the system tab bar this
    /// shell replaces. Order here is the on-screen order.
    enum Tab: String, CaseIterable, Identifiable {
        case home
        case downloader
        case videos
        case network
        case more

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .downloader: return "Downloader"
            case .videos: return "Videos"
            case .network: return "Network"
            case .more: return "More"
            }
        }

        /// Outline icon for the resting state…
        var icon: String {
            switch self {
            case .home: return "house"
            case .downloader: return "arrow.down.circle"
            case .videos: return "play.rectangle"
            case .network: return "antenna.radiowaves.left.and.right"
            case .more: return "ellipsis.circle"
            }
        }

        /// …and its filled counterpart for the selected state. The antenna
        /// symbol has no fill variant, so it stays the same.
        var selectedIcon: String {
            switch self {
            case .home: return "house.fill"
            case .downloader: return "arrow.down.circle.fill"
            case .videos: return "play.rectangle.fill"
            case .network: return "antenna.radiowaves.left.and.right"
            case .more: return "ellipsis.circle.fill"
            }
        }
    }

    @State private var selection: Tab = .home
    @StateObject private var reconnectCoordinator = ForegroundReconnectCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInactive = false
    @State private var homeRefreshToken = 0
    @State private var videosRefreshToken = 0
    @State private var networkRefreshToken = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView(
                selectedTab: $selection,
                reconnectCycle: reconnectCoordinator.cycle,
                reconnectRefreshToken: homeRefreshToken
            )
                .tag(Tab.home)
                .toolbar(.hidden, for: .tabBar)

            DownloaderView()
                .tag(Tab.downloader)
                .toolbar(.hidden, for: .tabBar)

            VideosView(
                reconnectCycle: reconnectCoordinator.cycle,
                reconnectRefreshToken: videosRefreshToken
            )
                .tag(Tab.videos)
                .toolbar(.hidden, for: .tabBar)

            NetworkUsageView(
                reconnectCycle: reconnectCoordinator.cycle,
                reconnectRefreshToken: networkRefreshToken
            )
                .tag(Tab.network)
                .toolbar(.hidden, for: .tabBar)

            MoreView()
                .tag(Tab.more)
                .toolbar(.hidden, for: .tabBar)
        }
        // The custom bar lives in the bottom safe-area inset, so every tab's
        // content (scroll views and web views alike) is automatically laid out
        // above it — nothing hides behind the bar, and the bar itself sits
        // clear of the home indicator.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CloudBoxTabBar(selection: $selection)
        }
        .overlay(alignment: .top) {
            reconnectIndicator
                .padding(.top, 8)
        }
        .tint(Color(red: 0.42, green: 0.76, blue: 1.0))
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                guard wasInactive else { return }
                wasInactive = false
                reconnectCoordinator.start()
            } else {
                wasInactive = true
                reconnectCoordinator.cancel()
            }
        }
        .onChange(of: reconnectCoordinator.completedCycle) { _ in
            homeRefreshToken += 1
            videosRefreshToken += 1
            networkRefreshToken += 1
        }
    }

    @ViewBuilder
    private var reconnectIndicator: some View {
        switch reconnectCoordinator.status {
        case .idle, .connected:
            EmptyView()
        case .reconnecting:
            Label("Reconnecting…", systemImage: "network")
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        case .unavailable:
            Link(destination: URL(string: "tailscale://")!) {
                Label("Server unavailable · Open Tailscale", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.88), in: Capsule())
            }
        }
    }
}

@MainActor
final class ForegroundReconnectCoordinator: ObservableObject {
    enum Status {
        case idle
        case reconnecting
        case connected
        case unavailable
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var cycle = 0
    @Published private(set) var completedCycle = 0

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        cycle += 1
        let activeCycle = cycle
        status = .reconnecting

        task = Task {
            let delays: [UInt64] = [0, 750_000_000, 2_000_000_000]
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }

                if await probeHealth() {
                    guard !Task.isCancelled, activeCycle == cycle else { return }
                    status = .connected
                    completedCycle += 1
                    return
                }
            }

            guard !Task.isCancelled, activeCycle == cycle else { return }
            status = .unavailable

            while !Task.isCancelled, activeCycle == cycle {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, activeCycle == cycle else { return }

                if await probeHealth() {
                    guard !Task.isCancelled, activeCycle == cycle else { return }
                    status = .connected
                    completedCycle += 1
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func probeHealth() async -> Bool {
        guard let url = URL(string: "\(CompletedFilesAPI.baseURL)/api/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 9

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

/// CloudBox's custom navigation shell: a floating pill bar in the same visual
/// language as the Home dashboard — flat raised navy, hairline stroke, one
/// blue accent. The selected tab gets a tinted chip that slides between items;
/// unselected tabs stay quiet but always keep icon + label for clarity.
private struct CloudBoxTabBar: View {
    @Binding var selection: RootTabView.Tab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chipNamespace

    // Tokens mirrored from the Home redesign so shell + content read as one.
    private let surfaceRaised = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let hairline = Color.white.opacity(0.08)
    private let mutedText = Color(red: 0.50, green: 0.58, blue: 0.72)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)
    private let selectedText = Color(red: 0.72, green: 0.88, blue: 1.0)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RootTabView.Tab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(surfaceRaised.opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func tabButton(_ tab: RootTabView.Tab) -> some View {
        let isSelected = selection == tab

        return Button {
            select(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 18, weight: .semibold))

                Text(tab.title)
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? selectedText : mutedText)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(premiumBlue.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(premiumBlue.opacity(0.28), lineWidth: 1)
                        }
                        .matchedGeometryEffect(id: "selectedChip", in: chipNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Switch tabs with a light selection haptic and a short spring that
    /// slides the chip. Reduce Motion drops the animation, never the switch.
    private func select(_ tab: RootTabView.Tab) {
        guard tab != selection else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if reduceMotion {
            selection = tab
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                selection = tab
            }
        }
    }
}

/// Press feedback for tab items: a slight settle, consistent with the press
/// styles used across CloudBox screens.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MoreView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let background = Color(red: 0.015, green: 0.035, blue: 0.075)
    private let panel = Color(red: 0.025, green: 0.075, blue: 0.145)
    private let elevatedPanel = Color(red: 0.035, green: 0.105, blue: 0.205)
    private let stroke = Color(red: 0.20, green: 0.31, blue: 0.48)
    private let muted = Color(red: 0.62, green: 0.68, blue: 0.80)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    moreHero

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Server Tools")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(muted)
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .padding(.horizontal, 2)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 12) {
                            NavigationLink {
                                QBittorrentView()
                            } label: {
                                moreRow(
                                    title: "qBittorrent",
                                    subtitle: "Manage remote torrents",
                                    systemImage: "magnet",
                                    tint: .orange
                                )
                            }
                            .buttonStyle(MorePressStyle())

                            NavigationLink {
                                FilesView()
                            } label: {
                                moreRow(
                                    title: "Files",
                                    subtitle: "Browse CloudBox storage",
                                    systemImage: "folder.fill",
                                    tint: .blue
                                )
                            }
                            .buttonStyle(MorePressStyle())

                            NavigationLink {
                                TrendsView()
                            } label: {
                                moreRow(
                                    title: "Trends",
                                    subtitle: "TMDB movies and series",
                                    systemImage: "chart.line.uptrend.xyaxis",
                                    tint: .mint
                                )
                            }
                            .buttonStyle(MorePressStyle())

                            NavigationLink {
                                MarkdownConverterView()
                            } label: {
                                moreRow(
                                    title: "Markdown Converter",
                                    subtitle: "Convert documents to Markdown",
                                    systemImage: "doc.plaintext",
                                    tint: .cyan
                                )
                            }
                            .buttonStyle(MorePressStyle())

                            NavigationLink {
                                SettingsView()
                            } label: {
                                moreRow(
                                    title: "Settings",
                                    subtitle: "CloudBox app preferences",
                                    systemImage: "gearshape.fill",
                                    tint: .gray
                                )
                            }
                            .buttonStyle(MorePressStyle())
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .background(moreBackground)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var moreBackground: some View {
        ZStack {
            background.ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.10, blue: 0.20),
                    background,
                    Color(red: 0.0, green: 0.01, blue: 0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.blue.opacity(0.16), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 320
            )
            .ignoresSafeArea()
        }
    }

    private var moreHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    moreHeroIcon
                    moreHeroText
                }
            } else {
                HStack(spacing: 16) {
                    moreHeroIcon
                    moreHeroText
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.18, blue: 0.38), panel.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.blue.opacity(0.52), lineWidth: 1.25)
        }
        .shadow(color: Color.blue.opacity(0.20), radius: 22, y: 12)
    }

    private var moreHeroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.34), elevatedPanel.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 72, height: 72)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.blue.opacity(0.46), lineWidth: 1)
                }

            Image(systemName: "shippingbox.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var moreHeroText: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("More")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text("CloudBox controls and server tools")
                .font(.body.weight(.medium))
                .foregroundStyle(muted)
                .lineLimit(3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private func moreRow(title: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        moreRowIcon(systemImage, tint: tint)
                        Spacer(minLength: 8)
                        moreRowChevron
                    }
                    moreRowText(title: title, subtitle: subtitle)
                }
            } else {
                HStack(spacing: 15) {
                    moreRowIcon(systemImage, tint: tint)
                    moreRowText(title: title, subtitle: subtitle)
                    Spacer(minLength: 8)
                    moreRowChevron
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.18), elevatedPanel.opacity(0.86), panel.opacity(0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.40), lineWidth: 1.25)
        }
        .shadow(color: tint.opacity(0.12), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(.isButton)
    }

    private func moreRowIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tint.opacity(0.38), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private func moreRowText(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(muted)
                .lineLimit(3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var moreRowChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(muted)
            .frame(width: 34, height: 34)
            .background(elevatedPanel.opacity(0.60), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct MorePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    RootTabView()
}
