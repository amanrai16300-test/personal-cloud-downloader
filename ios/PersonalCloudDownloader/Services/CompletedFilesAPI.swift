import Foundation

/// Minimal client for the private backend `/api/completed-files` endpoint.
///
/// Reached over Tailscale only. No other endpoints are used yet.
enum CompletedFilesAPI {
    static let baseURL = "http://100.92.146.101:8000"

    /// Video extensions surfaced in the Videos library.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    /// Fetch completed files, then keep only video files (client-side filter).
    static func fetchVideos() async throws -> [CompletedFile] {
        guard let url = URL(string: "\(baseURL)/api/completed-files") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let files = try JSONDecoder().decode([CompletedFile].self, from: data)
        return files.filter { videoExtensions.contains($0.fileExtension) }
    }
}
