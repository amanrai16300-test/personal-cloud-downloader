import SwiftUI

struct VideosView: View {
    @State private var videos: [CompletedFile] = []
    @State private var progressByPath: [String: VideoProgress] = [:]
    @State private var phase: LoadPhase = .loading
    private let background = Color(red: 0.015, green: 0.035, blue: 0.075)
    private let panel = Color(red: 0.025, green: 0.075, blue: 0.145)
    private let stroke = Color(red: 0.20, green: 0.31, blue: 0.48)
    private let muted = Color(red: 0.62, green: 0.68, blue: 0.80)

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case error(String)
    }

    var body: some View {
        NavigationStack {
            content
                .background(videosBackground)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
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
            loadingView

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
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                videosHeader(grouped)

                VStack(spacing: 14) {
                    ForEach(grouped.folders) { folder in
                        NavigationLink(value: folder) {
                            folderRow(folder)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(grouped.looseVideos) { video in
                        NavigationLink(value: video) {
                            videoCard(video, progress: progressByPath[video.path])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .refreshable { await load() }
    }

    private var videosBackground: some View {
        ZStack {
            background.ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.10, blue: 0.20),
                    background,
                    Color(red: 0.0, green: 0.01, blue: 0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.blue.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 320
            )
            .ignoresSafeArea()
        }
    }

    private func videosHeader(_ grouped: VideoGrouping.Result) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Videos")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    summaryRow(grouped)
                }

                Spacer()

                HStack(spacing: 14) {
                    headerIcon("magnifyingglass")
                    headerIcon("slider.horizontal.3")
                }
            }
        }
    }

    private func summaryRow(_ grouped: VideoGrouping.Result) -> some View {
        HStack(spacing: 7) {
            Text(grouped.folders.count == 1 ? "1 folder" : "\(grouped.folders.count) folders")
                .foregroundStyle(muted)
            Text("•")
                .foregroundStyle(Color.purple)
            Text(videos.count == 1 ? "1 video" : "\(videos.count) videos")
                .foregroundStyle(Color.purple)
        }
        .font(.system(size: 18, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(muted)
            .frame(width: 56, height: 56)
            .background(panel.opacity(0.72), in: Circle())
            .overlay(Circle().stroke(stroke.opacity(0.42), lineWidth: 1))
    }

    /// File-manager-style folder row: folder glyph, torrent name, video count.
    private func folderRow(_ folder: VideoFolder) -> some View {
        HStack(spacing: 18) {
            folderIcon

            VStack(alignment: .leading, spacing: 9) {
                Text(folder.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(folder.videoCountLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(muted)

                if let date = folder.latestModifiedDate {
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(stroke.opacity(0.34), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var folderIcon: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.36, green: 0.50, blue: 1.0),
                            Color(red: 0.18, green: 0.55, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 70, height: 56)
                .offset(y: 9)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.38, green: 0.42, blue: 1.0))
                .frame(width: 34, height: 18)
        }
        .frame(width: 76, height: 70)
        .shadow(color: Color.blue.opacity(0.24), radius: 12, y: 8)
    }

    /// A single video row (loose, or inside a folder). Shows the clean filename.
    private func videoRow(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        VideoRow(video: video, progress: progress)
    }

    private func videoCard(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 76, height: 70)

            VStack(alignment: .leading, spacing: 9) {
                Text(video.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let date = video.modifiedDate {
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(stroke.opacity(0.34), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // iOS 16-compatible empty state. `ContentUnavailableView` is iOS 17+, and
    // the deployment target is 16.0, so this is built from plain views instead.
    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.slash")
                .font(.largeTitle)
                .foregroundStyle(muted)
            Text("No Videos")
                .font(.headline)
                .foregroundStyle(.white)
            Text("No completed video files were found.")
                .font(.footnote)
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        ProgressView("Loading videos…")
            .tint(.blue)
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(muted)
            Text("Failed to load videos")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(muted)
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

    var latestModifiedDate: Date? {
        videos.compactMap(\.modifiedDate).max()
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
