import Foundation

struct VideoProgress: Codable, Hashable {
    let path: String
    let timeMs: Int
    let durationMs: Int
    let watchedPercent: Double
    let updatedAt: String?

    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        return ISO8601DateFormatter().date(from: updatedAt)
    }

    static func local(path: String, timeMs: Int, durationMs: Int) -> VideoProgress {
        let percent = durationMs > 0 ? min(max(Double(timeMs) / Double(durationMs) * 100, 0), 100) : 0
        return VideoProgress(
            path: path,
            timeMs: timeMs,
            durationMs: durationMs,
            watchedPercent: percent,
            updatedAt: nil
        )
    }
}

/// Minimal client for the private backend `/api/completed-files` endpoint.
///
/// Reached over Tailscale only. No other endpoints are used yet.
enum CompletedFilesAPI {
    static let baseURL = CloudBoxEndpoints.fastAPIBaseURL.absoluteString

    /// Video extensions surfaced in the Videos library.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    /// Fetch completed files, then keep only video files (client-side filter).
    static func fetchVideos() async throws -> [CompletedFile] {
        guard let url = URL(string: "\(baseURL)/api/completed-files") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 9
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let files = try JSONDecoder().decode([CompletedFile].self, from: data)
        return files.filter { videoExtensions.contains($0.fileExtension) }
    }

    static func fetchVideoProgress() async throws -> [String: VideoProgress] {
        guard let url = URL(string: "\(baseURL)/api/video-progress") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 9
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let progress = try JSONDecoder().decode([VideoProgress].self, from: data)
        return Dictionary(uniqueKeysWithValues: progress.map { ($0.path, $0) })
    }

    static func saveVideoProgress(path: String, timeMs: Int, durationMs: Int) async throws {
        guard let url = URL(string: "\(baseURL)/api/video-progress") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            VideoProgressPayload(path: path, timeMs: timeMs, durationMs: durationMs)
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private struct VideoProgressPayload: Encodable {
        let path: String
        let timeMs: Int
        let durationMs: Int
    }
}
