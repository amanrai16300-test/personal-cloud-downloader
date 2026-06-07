import SwiftUI

struct QBittorrentView: View {
    // Private qBittorrent Web UI, reached over Tailscale.
    private let url = URL(string: "http://100.95.39.107:8080")!

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    QBittorrentView()
}
