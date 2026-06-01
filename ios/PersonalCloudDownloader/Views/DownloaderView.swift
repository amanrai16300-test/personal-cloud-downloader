import SwiftUI

struct DownloaderView: View {
    // Private Personal Cloud Downloader web UI, reached over Tailscale.
    private let url = URL(string: "http://100.92.146.101:8090/app/")!

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    DownloaderView()
}
