import SwiftUI

/// Reusable web screen: a `WebView` plus minimal loading and error UI.
///
/// Tabs (Downloader, qBittorrent, Files) will use this later by passing a URL.
/// No URLs are wired in yet.
struct WebScreen: View {
    let url: URL

    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        ZStack {
            WebView(url: url, isLoading: $isLoading, error: $error)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
            }

            if let error {
                errorView(error)
            }
        }
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Failed to load")
                .font(.headline)

            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
