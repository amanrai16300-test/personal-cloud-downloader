import SwiftUI

struct QBittorrentView: View {
    // Private qBittorrent Web UI, reached over Tailscale.
    private let url = URL(string: "http://100.92.146.101:8080")!

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    QBittorrentView()
}
