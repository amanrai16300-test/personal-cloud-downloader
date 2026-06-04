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
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    QBittorrentView()
                } label: {
                    Label("qBittorrent", systemImage: "magnet")
                }

                NavigationLink {
                    FilesView()
                } label: {
                    Label("Files", systemImage: "folder")
                }

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("More")
        }
    }
}

#Preview {
    RootTabView()
}
