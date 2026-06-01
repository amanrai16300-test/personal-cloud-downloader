import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL

    private let tailscaleIP = "100.92.146.101"
    private let downloaderURL = "http://100.92.146.101:8090/app/"
    private let qbittorrentURL = "http://100.92.146.101:8080"
    private let filesURL = "http://100.92.146.101:8090/files/"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Personal Cloud Downloader")
                        .font(.headline)
                }

                Section("Server") {
                    infoRow(label: "Oracle Tailscale IP", value: tailscaleIP)
                    infoRow(label: "Downloader", value: downloaderURL)
                    infoRow(label: "qBittorrent", value: qbittorrentURL)
                    infoRow(label: "Files", value: filesURL)
                }

                Section("Privacy") {
                    Label(
                        "This app works only through Tailscale / private network.",
                        systemImage: "lock.shield"
                    )
                    Text("Do not expose Oracle ports publicly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Tailscale") {
                    Text("Open Tailscale and confirm the VPN is connected before using the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        if let url = URL(string: "tailscale://") {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Tailscale", systemImage: "network")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    SettingsView()
}
