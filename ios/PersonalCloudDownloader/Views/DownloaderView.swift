import SwiftUI

struct DownloaderView: View {
    // Private Personal Cloud Downloader web UI, reached over Tailscale.
    private let url = URL(string: "http://100.95.39.107:8090/app/")!

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    DownloaderView()
}
