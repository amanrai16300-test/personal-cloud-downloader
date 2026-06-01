import SwiftUI

struct VideosView: View {
    @State private var videos: [CompletedFile] = []
    @State private var phase: LoadPhase = .loading

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case error(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Videos")
                .navigationDestination(for: CompletedFile.self) { video in
                    PlayerView(video: video)
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading videos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            errorView(message)

        case .loaded:
            if videos.isEmpty {
                emptyView
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(videos) { video in
            NavigationLink(value: video) {
                row(video)
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private func row(_ video: CompletedFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(video.displayName)
                    .font(.callout)
                    .lineLimit(2)
                if let date = video.modifiedDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    // iOS 16-compatible empty state. `ContentUnavailableView` is iOS 17+, and
    // the deployment target is 16.0, so this is built from plain views instead.
    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Videos")
                .font(.headline)
            Text("No completed video files were found.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Failed to load videos")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        phase = .loading
        do {
            videos = try await CompletedFilesAPI.fetchVideos()
            phase = .loaded
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}

#Preview {
    VideosView()
}
