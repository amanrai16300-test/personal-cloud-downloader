import SwiftUI

struct VideosView: View {
    @State private var videos: [CompletedFile] = []
    @State private var progressByPath: [String: VideoProgress] = [:]
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
                // A tapped loose video (no parent folder) opens straight into
                // fullscreen, same as before. A tapped folder pushes the list of
                // videos inside it.
                .navigationDestination(for: CompletedFile.self) { video in
                    PlayerView(video: video, startsFullscreen: true)
                }
                .navigationDestination(for: VideoFolder.self) { folder in
                    FolderVideosView(folder: folder, progressByPath: progressByPath)
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

    /// Folder-style list: one row per torrent folder first, then any loose
    /// videos that have no parent folder. Grouping is recomputed from `videos`
    /// each render, so pull-to-refresh reflows automatically.
    private var list: some View {
        let grouped = VideoGrouping.group(videos)
        return List {
            if !grouped.folders.isEmpty {
                Section {
                    ForEach(grouped.folders) { folder in
                        NavigationLink(value: folder) {
                            folderRow(folder)
                        }
                    }
                }
            }
            if !grouped.looseVideos.isEmpty {
                Section {
                    ForEach(grouped.looseVideos) { video in
                        NavigationLink(value: video) {
                            videoRow(video, progress: progressByPath[video.path])
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    /// File-manager-style folder row: folder glyph, torrent name, video count.
    private func folderRow(_ folder: VideoFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.callout)
                    .lineLimit(2)
                Text(folder.videoCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// A single video row (loose, or inside a folder). Shows the clean filename.
    private func videoRow(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        VideoRow(video: video, progress: progress)
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
            let fetchedVideos = try await CompletedFilesAPI.fetchVideos()
            let backendProgress = (try? await CompletedFilesAPI.fetchVideoProgress()) ?? [:]
            let localProgress = VLCPlayerController.localProgressSnapshot()
            let mergedProgress = Self.mergeProgress(backend: backendProgress, local: localProgress)
            videos = fetchedVideos
            progressByPath = mergedProgress
            VLCPlayerController.importProgressSnapshot(mergedProgress)
            phase = .loaded
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private static func mergeProgress(
        backend: [String: VideoProgress],
        local: [String: VideoProgress]
    ) -> [String: VideoProgress] {
        var merged = backend
        for (path, localProgress) in local {
            guard let backendProgress = merged[path] else {
                merged[path] = localProgress
                continue
            }

            if let backendDate = backendProgress.updatedDate,
               let localDate = localProgress.updatedDate {
                merged[path] = localDate > backendDate ? localProgress : backendProgress
            } else if localProgress.timeMs > backendProgress.timeMs,
                      localProgress.durationMs > 0 {
                merged[path] = localProgress
            }
        }
        return merged
    }
}

/// One torrent folder: its display name and the videos inside it. Grouped from
/// the flat `CompletedFile` list by the first path component of each file's
/// relative `name` (the torrent folder). Used as a `navigationDestination`
/// value, so it must be `Hashable`.
struct VideoFolder: Identifiable, Hashable {
    let name: String
    let videos: [CompletedFile]

    var id: String { name }

    /// "8 videos" / "1 video" — simple count label for the folder row.
    var videoCountLabel: String {
        videos.count == 1 ? "1 video" : "\(videos.count) videos"
    }
}

/// Pure grouping of the flat video list into folders + loose videos. Keeps the
/// view body simple and the logic unit-testable. No model/API change needed —
/// the torrent folder is just the first path component of `CompletedFile.name`
/// (which the backend sends as the relative path, e.g. "Show/Ep1.mkv").
enum VideoGrouping {
    struct Result {
        let folders: [VideoFolder]
        let looseVideos: [CompletedFile]
    }

    /// First path component of a relative `name`, or nil when the file has no
    /// parent folder (a bare filename with no "/"). Trailing/leading slashes are
    /// ignored so "Show/Ep.mkv" and "/Show/Ep.mkv" both yield "Show".
    static func folderName(of video: CompletedFile) -> String? {
        let parts = video.name
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count > 1 else { return nil } // no folder, just a filename
        return parts.first
    }

    /// Group into folder rows (sorted by name) followed by loose videos. Folder
    /// order and the videos within each folder are sorted by name for a stable,
    /// readable layout that doesn't reshuffle between refreshes.
    static func group(_ videos: [CompletedFile]) -> Result {
        var byFolder: [String: [CompletedFile]] = [:]
        var loose: [CompletedFile] = []

        for video in videos {
            if let folder = folderName(of: video) {
                byFolder[folder, default: []].append(video)
            } else {
                loose.append(video)
            }
        }

        let folders = byFolder
            .map { name, vids in
                VideoFolder(
                    name: name,
                    videos: vids.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        loose.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return Result(folders: folders, looseVideos: loose)
    }
}

/// The videos inside one torrent folder. Reuses the same direct-fullscreen open
/// behavior: each row pushes `PlayerView(startsFullscreen: true)` via the parent
/// stack's `CompletedFile` navigation destination.
private struct FolderVideosView: View {
    let folder: VideoFolder
    let progressByPath: [String: VideoProgress]

    var body: some View {
        List(folder.videos) { video in
            NavigationLink(value: video) {
                row(video, progress: progressByPath[video.path])
            }
        }
        .listStyle(.plain)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        VideoRow(video: video, progress: progress)
    }
}

private struct VideoRow: View {
    let video: CompletedFile
    let progress: VideoProgress?

    private var watchedPercent: Double {
        min(max(progress?.watchedPercent ?? 0, 0), 100)
    }

    private var showsProgress: Bool {
        watchedPercent > 5
    }

    private var isWatched: Bool {
        watchedPercent >= 70
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: isWatched ? "checkmark.rectangle.fill" : "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(isWatched ? Color.secondary : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(video.displayName)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        if isWatched {
                            watchedBadge
                        }
                    }

                    if let date = video.modifiedDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .opacity(isWatched ? 0.86 : 1)

            if showsProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(isWatched ? Color.green.opacity(0.72) : Color.accentColor.opacity(0.72))
                            .frame(width: geo.size.width * CGFloat(watchedPercent / 100))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 40)
            }
        }
        .contentShape(Rectangle())
    }

    private var watchedBadge: some View {
        Label("Watched", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.green.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

#Preview {
    VideosView()
}
