import SwiftUI
import UIKit

struct RootTabView: View {
    init() {
        Self.configureTabBarAppearance()
    }

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            DownloaderView()
                .tabItem {
                    Label("Downloader", systemImage: "arrow.down.circle")
                }

            VideosView()
                .tabItem {
                    Label("Videos", systemImage: "play.rectangle")
                }

            NetworkUsageView()
                .tabItem {
                    Label("Network", systemImage: "antenna.radiowaves.left.and.right")
                }

            MoreView()
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
        }
        .tint(Color(red: 0.42, green: 0.76, blue: 1.0))
    }

    private static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.012, green: 0.028, blue: 0.060, alpha: 0.98)
        appearance.shadowColor = UIColor(red: 0.12, green: 0.24, blue: 0.42, alpha: 0.75)

        let selected = UIColor(red: 0.72, green: 0.88, blue: 1.0, alpha: 1)
        let normal = UIColor(red: 0.46, green: 0.54, blue: 0.68, alpha: 1)

        configureTabItem(appearance.stackedLayoutAppearance, selected: selected, normal: normal)
        configureTabItem(appearance.inlineLayoutAppearance, selected: selected, normal: normal)
        configureTabItem(appearance.compactInlineLayoutAppearance, selected: selected, normal: normal)

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().isTranslucent = false
    }

    private static func configureTabItem(_ item: UITabBarItemAppearance, selected: UIColor, normal: UIColor) {
        item.selected.iconColor = selected
        item.selected.titleTextAttributes = [
            .foregroundColor: selected,
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        item.normal.iconColor = normal
        item.normal.titleTextAttributes = [
            .foregroundColor: normal,
            .font: UIFont.systemFont(ofSize: 11, weight: .medium)
        ]
    }
}

private struct MoreView: View {
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
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(muted)
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .padding(.horizontal, 2)

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
        HStack(spacing: 16) {
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

            VStack(alignment: .leading, spacing: 7) {
                Text("More")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Text("CloudBox controls and server tools")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(2)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
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

    private func moreRow(title: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 15) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.38), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(muted)
                .frame(width: 34, height: 34)
                .background(elevatedPanel.opacity(0.60), in: Circle())
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
