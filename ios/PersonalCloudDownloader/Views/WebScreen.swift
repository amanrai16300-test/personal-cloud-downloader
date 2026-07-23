import SwiftUI

/// Reusable web screen: a `WebView` plus minimal loading and error UI.
///
/// Tabs (Downloader, qBittorrent, Files) will use this later by passing a URL.
/// No URLs are wired in yet.
struct WebScreen: View {
    let url: URL

    @State private var isLoading = false
    @State private var error: Error?
    @State private var reloadGeneration = 0
    @State private var retryInProgress = false

    var body: some View {
        ZStack {
            WebView(
                url: url,
                isLoading: $isLoading,
                error: $error,
                reloadGeneration: reloadGeneration
            )

            if isLoading {
                ProgressView()
                    .controlSize(.large)
            }

            if let error {
                errorView(error)
            }
        }
        .onChange(of: isLoading) { loading in
            if !loading {
                retryInProgress = false
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

            Button("Retry") {
                guard !retryInProgress else { return }
                retryInProgress = true
                self.error = nil
                reloadGeneration += 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(retryInProgress)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
