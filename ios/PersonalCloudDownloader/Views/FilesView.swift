import SwiftUI

struct FilesView: View {
    // Private Nginx file browser, reached over Tailscale.
    private let url = URL(string: "http://100.92.146.101:8090/files/")!

    var body: some View {
        WebScreen(url: url)
    }
}

#Preview {
    FilesView()
}
