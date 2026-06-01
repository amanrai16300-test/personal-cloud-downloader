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

            QBittorrentView()
                .tabItem {
                    Label("qBittorrent", systemImage: "magnet")
                }

            FilesView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    RootTabView()
}
