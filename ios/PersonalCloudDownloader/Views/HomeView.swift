import SwiftUI

struct HomeView: View {
    private let serverIP = "100.92.146.101"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    connectionCard
                    screenGuide
                    safetyNote
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Home")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Personal Cloud Downloader")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Private cloud downloader companion")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Connect Tailscale before using the app.", systemImage: "network")
                .font(.callout)
                .fontWeight(.medium)
            Text("Server: \(serverIP)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var screenGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screens")
                .font(.headline)

            guideRow(icon: "arrow.down.circle", title: "Downloader",
                     detail: "Add magnets, see progress, completed files, stream/download/delete.")
            guideRow(icon: "play.rectangle", title: "Videos",
                     detail: "Video library/player will be added later.")
            guideRow(icon: "magnet", title: "qBittorrent",
                     detail: "Advanced torrent control.")
            guideRow(icon: "folder", title: "Files",
                     detail: "Raw Nginx file browser.")
            guideRow(icon: "gearshape", title: "Settings",
                     detail: "Server info and Tailscale helper.")
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Legal files only.", systemImage: "checkmark.shield")
                .font(.footnote)
            Label("Keep Oracle private through Tailscale.", systemImage: "lock.shield")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

#Preview {
    HomeView()
}
