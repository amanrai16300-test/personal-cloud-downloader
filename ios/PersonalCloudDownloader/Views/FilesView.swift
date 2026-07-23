import SwiftUI

struct FilesView: View {
    // Private Nginx file browser, reached over Tailscale.
    private let url = CloudBoxEndpoints.filesURL

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    FilesView()
}
