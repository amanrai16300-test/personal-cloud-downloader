import SwiftUI

struct DownloaderView: View {
    // Private Personal Cloud Downloader web UI, reached over Tailscale.
    private let url = CloudBoxEndpoints.downloaderWebAppURL

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    DownloaderView()
}
