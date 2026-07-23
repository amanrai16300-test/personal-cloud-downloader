import SwiftUI

struct QBittorrentView: View {
    // Private qBittorrent Web UI, reached over Tailscale.
    private let url = CloudBoxEndpoints.qBittorrentURL

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    QBittorrentView()
}
