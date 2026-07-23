import Foundation
import SwiftUI

private let watchedCompletionPercent = 90.0

private enum VideoRowAccessibility {
    static func label(title: String, progress: VideoProgress?) -> String {
        hasValidProgress(progress) ? "\(title), Watch progress" : title
    }

    static func value(progress: VideoProgress?, modifiedDate: Date?) -> String {
        var details: [String] = []

        if let progress, hasValidProgress(progress) {
            let watchedPercent = min(max(progress.watchedPercent, 0), 100)
            let percent = Int(watchedPercent.rounded())
            if watchedPercent >= watchedCompletionPercent {
                details.append("Watched")
            }
            details.append("\(percent) percent")
            details.append("Duration \(durationText(progress.durationMs))")
        }

        if let modifiedDate {
            details.append(
                "Modified \(modifiedDate.formatted(date: .abbreviated, time: .shortened))"
            )
        }

        return details.joined(separator: ", ")
    }

    private static func hasValidProgress(_ progress: VideoProgress?) -> Bool {
        guard let progress else { return false }
        return progress.durationMs > 0 && progress.timeMs >= 0
    }

    private static func durationText(_ durationMs: Int) -> String {
        let totalSeconds = durationMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        var parts: [String] = []

        if hours > 0 {
            parts.append(hours == 1 ? "1 hour" : "\(hours) hours")
        }
        if minutes > 0 {
            parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        }
        if hours == 0, seconds > 0 {
            parts.append(seconds == 1 ? "1 second" : "\(seconds) seconds")
        }

        return parts.isEmpty ? "0 seconds" : parts.joined(separator: ", ")
    }
}

struct VideosView: View {
    var reconnectCycle: Int = 0
    var reconnectRefreshToken: Int = 0

    @Environment(\.scenePhase) private var scenePhase
    @State private var videos: [CompletedFile] = []
    @State private var progressByPath: [String: VideoProgress] = [:]
    @State private var phase: LoadPhase = .loading
    @State private var isVisible = false
    @State private var loadGeneration = 0
    @State private var navigationPath = NavigationPath()
    @State private var loadTask: Task<Void, Never>?
    @State private var activeLoadID: UUID?
    @State private var hasStartedInitialLoad = false
    @State private var hasAppeared = false
    @State private var lastRootRefreshAt = Date.distantPast
    @State private var isShowingStaleRefreshNotice = false
    // Palette mirrored from the Home redesign tokens.
    private let background = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let panel = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let elevatedPanel = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let stroke = Color.white.opacity(0.22)
    private let muted = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case error(String)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
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
        .task {
            guard !hasStartedInitialLoad else { return }
            hasStartedInitialLoad = true
            await load()
        }
        .onAppear {
            isVisible = true
            if hasAppeared {
                refreshRootIfNeeded()
            } else {
                hasAppeared = true
            }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                loadGeneration += 1
                loadTask?.cancel()
                loadTask = nil
                activeLoadID = nil
            }
        }
        .onChange(of: reconnectCycle) { _ in
            guard isVisible else { return }
            startLoad(invalidateExisting: true)
        }
        .onChange(of: reconnectRefreshToken) { _ in
            guard isVisible else { return }
            startLoad()
        }
        .onChange(of: navigationPath.count) { depth in
            guard depth == 0 else { return }
            refreshRootIfNeeded()
        }
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

                if isShowingStaleRefreshNotice {
                    staleRefreshNotice
                }

                VStack(spacing: 12) {
                    ForEach(grouped.folders) { folder in
                        NavigationLink(value: folder) {
                            folderRow(folder)
                        }
                        .buttonStyle(CloudBoxPressStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(folder.name)
                        .accessibilityValue(folder.videoCountLabel)
                    }

                    ForEach(grouped.looseVideos) { video in
                        NavigationLink(value: video) {
                            videoCard(video, progress: progressByPath[video.path])
                        }
                        .buttonStyle(CloudBoxPressStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            VideoRowAccessibility.label(
                                title: video.displayName,
                                progress: progressByPath[video.path]
                            )
                        )
                        .accessibilityValue(
                            VideoRowAccessibility.value(
                                progress: progressByPath[video.path],
                                modifiedDate: video.modifiedDate
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .refreshable { await load() }
    }

    private var staleRefreshNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(premiumBlue)
                .accessibilityHidden(true)

            Text("Couldn’t refresh. Showing the last loaded library.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(elevatedPanel.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var videosBackground: some View {
        ZStack {
            background.ignoresSafeArea()
            RadialGradient(
                colors: [premiumBlue.opacity(0.12), .clear],
                center: .init(x: 0.9, y: -0.05),
                startRadius: 10,
                endRadius: 380
            )
            .ignoresSafeArea()
        }
    }

    private func videosHeader(_ grouped: VideoGrouping.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEDIA LIBRARY")
                .font(.caption2.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(premiumBlue)

            Text("Videos")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            summaryRow(grouped)
                .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func summaryRow(_ grouped: VideoGrouping.Result) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summaryPill(
                    icon: "folder.fill",
                    text: grouped.folders.count == 1 ? "1 folder" : "\(grouped.folders.count) folders"
                )
                summaryPill(
                    icon: "play.rectangle.fill",
                    text: videos.count == 1 ? "1 video" : "\(videos.count) videos"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                summaryPill(
                    icon: "folder.fill",
                    text: grouped.folders.count == 1 ? "1 folder" : "\(grouped.folders.count) folders"
                )
                summaryPill(
                    icon: "play.rectangle.fill",
                    text: videos.count == 1 ? "1 video" : "\(videos.count) videos"
                )
            }
        }
    }

    private func summaryPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(premiumBlue)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(elevatedPanel.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// Folder row: tinted folder chip, torrent name, count pill + date. Flat
    /// raised surface with a whisper of blue at the top edge — no gradients,
    /// no glow.
    private func folderRow(_ folder: VideoFolder) -> some View {
        HStack(spacing: 14) {
            folderIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(folder.name)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(folder.videoCountLabel)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(premiumBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(premiumBlue.opacity(0.13), in: Capsule())

                    if let date = folder.latestModifiedDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(muted)
                            .lineLimit(2)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(muted)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(elevatedPanel)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var folderIcon: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(premiumBlue)
            .frame(width: 52, height: 52)
            .background(premiumBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(premiumBlue.opacity(0.30), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    /// A single video row (loose, or inside a folder). Shows the clean filename.
    private func videoRow(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        VideoRow(video: video, progress: progress)
    }

    private func videoCard(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(premiumBlue)
                .frame(width: 52, height: 52)
                .background(premiumBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(premiumBlue.opacity(0.30), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(video.displayName)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let date = video.modifiedDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(muted)
                        .lineLimit(2)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(muted)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // iOS 16-compatible empty state. `ContentUnavailableView` is iOS 17+, and
    // the deployment target is 16.0, so this is built from plain views instead.
    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(muted)
                .frame(width: 76, height: 76)
                .background(panel.opacity(0.82), in: Circle())
                .overlay(Circle().stroke(stroke.opacity(0.42), lineWidth: 1))
            Text("No Videos")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("No completed video files were found.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(videosBackground)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.blue)
                .scaleEffect(1.15)
            VStack(spacing: 5) {
                Text("Loading videos")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Reading the CloudBox library")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(muted)
                    .lineLimit(3)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(videosBackground)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(muted)
                .frame(width: 76, height: 76)
                .background(panel.opacity(0.82), in: Circle())
                .overlay(Circle().stroke(stroke.opacity(0.42), lineWidth: 1))
            Text("Failed to load videos")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 18)
            Button {
                Task { await load() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(videosBackground)
    }

    @MainActor
    private func startLoad(invalidateExisting: Bool = false) {
        if invalidateExisting {
            loadGeneration += 1
            loadTask?.cancel()
        } else if activeLoadID != nil {
            return
        }

        let loadID = UUID()
        activeLoadID = loadID
        loadTask = Task {
            await load()
            guard activeLoadID == loadID else { return }
            activeLoadID = nil
            loadTask = nil
        }
    }

    @MainActor
    private func refreshRootIfNeeded() {
        guard isVisible, navigationPath.count == 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRootRefreshAt) >= 1 else { return }
        lastRootRefreshAt = now
        startLoad()
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if videos.isEmpty {
            phase = .loading
        }
        do {
            let fetchedVideos = try await CompletedFilesAPI.fetchVideos()
            let backendProgress = (try? await CompletedFilesAPI.fetchVideoProgress()) ?? [:]
            let localProgress = VLCPlayerController.localProgressSnapshot()
            let mergedProgress = Self.mergeProgress(backend: backendProgress, local: localProgress)
            guard generation == loadGeneration else { return }
            videos = fetchedVideos
            progressByPath = mergedProgress
            VLCPlayerController.importProgressSnapshot(mergedProgress)
            isShowingStaleRefreshNotice = false
            phase = .loaded
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            guard generation == loadGeneration else { return }
            if videos.isEmpty {
                isShowingStaleRefreshNotice = false
                phase = .error(error.localizedDescription)
            } else {
                isShowingStaleRefreshNotice = true
                phase = .loaded
            }
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

    /// Stable full path for the first relative folder component. Unlike the
    /// display name, this distinguishes equally named folders under other roots.
    static func folderIdentity(of video: CompletedFile) -> String? {
        let relativeParts = video.name
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let pathParts = video.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard relativeParts.count > 1,
              pathParts.count >= relativeParts.count,
              pathParts.suffix(relativeParts.count).elementsEqual(relativeParts)
        else { return nil }

        let rootParts = pathParts.dropLast(relativeParts.count)
        let folderParts = Array(rootParts) + [relativeParts[0]]
        let prefix = video.path.hasPrefix("/") ? "/" : ""
        return prefix + folderParts.joined(separator: "/")
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
///
/// Internal (not private) so the Home dashboard's separate `NavigationStack` can
/// register the same `VideoFolder` destination and reuse this exact episode-
/// picker screen for grouped series — no duplicate episode list.
struct FolderVideosView: View {
    let folder: VideoFolder
    private let initialProgressByPath: [String: VideoProgress]
    private let folderIdentity: String?
    @State private var visibleVideos: [CompletedFile]
    @State private var refreshedProgressByPath: [String: VideoProgress]
    @State private var folderRefreshGeneration = 0
    @State private var activeFolderRefreshID: UUID?
    private let background = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let panel = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let muted = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)

    init(folder: VideoFolder, progressByPath: [String: VideoProgress]) {
        self.folder = folder
        self.initialProgressByPath = progressByPath
        self.folderIdentity = folder.videos.first.flatMap(VideoGrouping.folderIdentity)
        _visibleVideos = State(initialValue: folder.videos)
        _refreshedProgressByPath = State(initialValue: progressByPath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                folderHeader

                VStack(spacing: 0) {
                    ForEach(visibleVideos) { video in
                        NavigationLink(value: video) {
                            row(video, progress: refreshedProgressByPath[video.path])
                        }
                        .buttonStyle(CloudBoxPressStyle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            VideoRowAccessibility.label(
                                title: video.displayName,
                                progress: refreshedProgressByPath[video.path]
                            )
                        )
                        .accessibilityValue(
                            VideoRowAccessibility.value(
                                progress: refreshedProgressByPath[video.path],
                                modifiedDate: video.modifiedDate
                            )
                        )

                        if video.id != visibleVideos.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.10))
                                .padding(.leading, 128)
                        }
                    }
                }
                .background(panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 34)
        }
        .background(folderBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if refreshedProgressByPath.isEmpty, !initialProgressByPath.isEmpty {
                refreshedProgressByPath = initialProgressByPath
            }
            startFolderRefresh()
        }
    }

    private func row(_ video: CompletedFile, progress: VideoProgress?) -> some View {
        FolderVideoRow(video: video, progress: progress)
    }

    @MainActor
    private func startFolderRefresh() {
        guard activeFolderRefreshID == nil else { return }

        folderRefreshGeneration += 1
        let generation = folderRefreshGeneration
        let refreshID = UUID()
        activeFolderRefreshID = refreshID

        Task {
            await refreshFolder(generation: generation)
            guard activeFolderRefreshID == refreshID else { return }
            activeFolderRefreshID = nil
        }
    }

    @MainActor
    private func refreshFolder(generation: Int) async {
        let backendProgress = (try? await CompletedFilesAPI.fetchVideoProgress()) ?? [:]
        let localProgress = VLCPlayerController.localProgressSnapshot()
        let fetchedVideos: [CompletedFile]

        do {
            fetchedVideos = try await CompletedFilesAPI.fetchVideos()
        } catch {
            guard generation == folderRefreshGeneration else { return }
            refreshedProgressByPath = Self.mergeProgressByPath(
                seed: refreshedProgressByPath.isEmpty ? initialProgressByPath : refreshedProgressByPath,
                backend: backendProgress,
                local: localProgress,
                videos: visibleVideos
            )
            return
        }

        guard generation == folderRefreshGeneration,
              let folderIdentity else { return }

        let latestVideos = fetchedVideos
            .filter { VideoGrouping.folderIdentity(of: $0) == folderIdentity }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        let merged = Self.mergeProgressByPath(
            seed: refreshedProgressByPath.isEmpty ? initialProgressByPath : refreshedProgressByPath,
            backend: backendProgress,
            local: localProgress,
            videos: latestVideos
        )
        visibleVideos = latestVideos
        refreshedProgressByPath = merged
    }

    private static func mergeProgressByPath(
        seed: [String: VideoProgress],
        backend: [String: VideoProgress],
        local: [String: VideoProgress],
        videos: [CompletedFile]
    ) -> [String: VideoProgress] {
        var merged = seed
        for video in videos {
            let path = video.path
            let candidates = [merged[path], backend[path], local[path]].compactMap { $0 }
            guard let latest = candidates.max(by: progressIsOlder) else { continue }
            merged[path] = latest
        }
        return merged
    }

    private static func progressIsOlder(_ lhs: VideoProgress, _ rhs: VideoProgress) -> Bool {
        switch (lhs.updatedDate, rhs.updatedDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            break
        }

        let lhsHasValidTime = lhs.timeMs > 0
        let rhsHasValidTime = rhs.timeMs > 0
        if lhsHasValidTime != rhsHasValidTime {
            return !lhsHasValidTime
        }
        if lhs.timeMs != rhs.timeMs {
            return lhs.timeMs < rhs.timeMs
        }

        let lhsHasValidDuration = lhs.durationMs > 0
        let rhsHasValidDuration = rhs.durationMs > 0
        if lhsHasValidDuration != rhsHasValidDuration {
            return !lhsHasValidDuration
        }
        return lhs.durationMs < rhs.durationMs
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FOLDER")
                .font(.caption2.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(premiumBlue)

            Text(folder.name)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(premiumBlue)
                    .accessibilityHidden(true)
                Text(visibleVideoCountLabel)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(panel, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private var visibleVideoCountLabel: String {
        visibleVideos.count == 1 ? "1 video" : "\(visibleVideos.count) videos"
    }

    private var folderBackground: some View {
        ZStack {
            background.ignoresSafeArea()
            RadialGradient(
                colors: [premiumBlue.opacity(0.12), .clear],
                center: .init(x: 0.9, y: -0.05),
                startRadius: 10,
                endRadius: 380
            )
            .ignoresSafeArea()
        }
    }
}

private struct FolderVideoRow: View {
    let video: CompletedFile
    let progress: VideoProgress?
    private let muted = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let elevatedPanel = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)

    private var watchedPercent: Double {
        min(max(progress?.watchedPercent ?? 0, 0), 100)
    }

    private var isWatched: Bool {
        watchedPercent >= watchedCompletionPercent
    }

    private var isPartiallyWatched: Bool {
        watchedPercent > 5 && watchedPercent < watchedCompletionPercent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            thumbnail
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(video.displayName)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                metadata

                HStack(spacing: 12) {
                    progressBar
                        .accessibilityHidden(true)
                    statusLabel
                        .accessibilityHidden(true)
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailImage

            if let durationText {
                Text(durationText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.70), in: Capsule())
                    .padding(6)
            }
        }
        .frame(width: 108, height: 70)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let url = video.thumbnailImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    thumbnailPlaceholder
                }
            }
            .frame(width: 108, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        } else {
            thumbnailPlaceholder
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        Color(red: 0.045, green: 0.055, blue: 0.07),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.28))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var metadata: some View {
        if let date = video.modifiedDate {
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.medium))
                .foregroundStyle(muted)
                .lineLimit(2)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(progressColor)
                    .frame(width: geo.size.width * CGFloat(watchedPercent / 100))
            }
        }
        .frame(height: 5)
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .bold))
            Text(statusText)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(progressColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 108, alignment: .center)
        .background(elevatedPanel.opacity(0.7), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var statusIcon: String {
        if isWatched {
            return "checkmark.circle.fill"
        }
        return "clock"
    }

    private var statusText: String {
        if isWatched {
            return "Watched"
        }
        if isPartiallyWatched {
            return "\(Int(watchedPercent.rounded()))% watched"
        }
        return "Not watched"
    }

    private var progressColor: Color {
        if isWatched {
            return .green
        }
        if isPartiallyWatched {
            return premiumBlue
        }
        return Color(red: 0.56, green: 0.64, blue: 0.78)
    }

    private var durationText: String? {
        guard let durationMs = progress?.durationMs, durationMs > 0 else { return nil }
        let totalSeconds = durationMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
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
        watchedPercent >= watchedCompletionPercent
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            VideoRowAccessibility.label(title: video.displayName, progress: progress)
        )
        .accessibilityValue(
            VideoRowAccessibility.value(progress: progress, modifiedDate: video.modifiedDate)
        )
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

private struct CloudBoxPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    VideosView()
}
