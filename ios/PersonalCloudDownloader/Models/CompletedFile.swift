import Foundation

/// One completed file from `GET /api/completed-files`.
///
/// Backend fields: name (relative path), path, url (stream link), modified_at
/// (ISO8601, nullable). No size field is provided by this endpoint.
struct CompletedFile: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let url: String
    let modifiedAt: String?

    // Stable identity from the unique stream URL.
    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case url
        case modifiedAt = "modified_at"
    }

    init(name: String, path: String, url: String, modifiedAt: String?) {
        self.name = name
        self.path = path
        self.url = url
        self.modifiedAt = modifiedAt
    }

    /// Last path component without directory prefix, e.g. "Big Buck Bunny.mp4".
    var displayName: String {
        (name as NSString).lastPathComponent
    }

    /// Lowercased file extension, e.g. "mp4".
    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    /// ISO8601 `modified_at` parsed to a `Date`, if present and valid.
    var modifiedDate: Date? {
        guard let modifiedAt else { return nil }
        return ISO8601DateFormatter().date(from: modifiedAt)
    }

    /// Playable stream URL resolved from the backend `url` field.
    ///
    /// The backend builds `url` as `{STREAM_BASE_URL}/{percent-encoded path}`.
    /// In the deployed config STREAM_BASE_URL is the Nginx `/files/` base, so
    /// `url` is already an absolute, percent-encoded http(s) link — we use it
    /// as-is and do NOT re-encode. Returns nil if `url` is empty, unparseable,
    /// or not an absolute http(s) URL (e.g. STREAM_BASE_URL was unset and the
    /// backend emitted a bare relative path).
    var streamURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed),
              let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              resolved.host != nil
        else { return nil }
        return resolved
    }

    /// Extensions playable by native AVPlayer / AVKit today. Other listed video
    /// formats (mkv, avi, webm) need the VLC engine added in a later step.
    static let avPlayerExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Whether this file can be played by native AVPlayer.
    var isAVPlayerSupported: Bool {
        Self.avPlayerExtensions.contains(fileExtension)
    }
}
