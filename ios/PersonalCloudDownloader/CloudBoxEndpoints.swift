import Foundation

enum CloudBoxEndpoints {
    static let serverHost = "100.95.39.107"

    static let fastAPIBaseURL = URL(string: "http://\(serverHost):8000")!
    static let qBittorrentURL = URL(string: "http://\(serverHost):8080")!
    static let filesWebBaseURL = URL(string: "http://\(serverHost):8090")!
    static let downloaderWebAppURL = URL(string: "\(filesWebBaseURL.absoluteString)/app/?v=direct-downloads-20260816")!
    static let filesURL = URL(string: "\(filesWebBaseURL.absoluteString)/files/")!
}
