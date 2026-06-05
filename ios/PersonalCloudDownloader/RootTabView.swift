import SwiftUI

struct RootTabView: View {
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
                    header

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moreRow(title: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 15) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.15), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.34), lineWidth: 1))

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
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            LinearGradient(
                colors: [elevatedPanel.opacity(0.82), panel.opacity(0.74)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(stroke.opacity(0.38), lineWidth: 1)
        }
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
