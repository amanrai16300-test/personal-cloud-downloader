# Personal Cloud Downloader iOS App Architecture

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## 1. Architecture summary

```text
iPhone SwiftUI App
│
├─ Native screens
│  ├─ Home
│  ├─ Videos
│  ├─ Video Player
│  └─ Settings/Tailscale Helper
│
├─ WebView screens
│  ├─ Downloader -> existing /app/
│  ├─ qBittorrent -> :8080
│  └─ Files -> /files/
│
└─ API client
   ├─ FastAPI backend :8000
   └─ Nginx files :8090/files/
```

Server side stays:

```text
Oracle Ubuntu
Tailscale
qBittorrent-nox
FastAPI
Nginx
Static web UI at /app/
```

---

## 2. Recommended iOS stack

```text
Language:
Swift

UI:
SwiftUI

IDE:
Xcode

Web panels:
WKWebView

Networking:
URLSession + async/await

JSON:
Codable

State:
ObservableObject / @StateObject / @Published

Local storage:
AppStorage or UserDefaults

Player:
MobileVLCKit / VLC-style engine

Fallback player:
AVPlayer / AVKit for MP4/MOV only
```

---

## 3. Why SwiftUI first

SwiftUI is better than Capacitor for this project because the app needs:

```text
Native Videos screen
Native video player screen
Better playback controls
VLC-style player integration
iOS-like navigation
```

Use web views only for screens that already exist as websites.

---

## 4. URL config

Keep URLs in one config file.

Example:

```swift
enum AppConfig {
    static let serverIP = "100.92.146.101"
    static let backendBaseURL = URL(string: "http://100.92.146.101:8000")!
    static let downloaderURL = URL(string: "http://100.92.146.101:8090/app/")!
    static let filesURL = URL(string: "http://100.92.146.101:8090/files/")!
    static let qBittorrentURL = URL(string: "http://100.92.146.101:8080")!
}
```

---

## 5. iOS folder structure

```text
PersonalCloudApp/
│
├─ App/
│  └─ PersonalCloudApp.swift
│
├─ Config/
│  └─ AppConfig.swift
│
├─ Models/
│  ├─ TorrentItem.swift
│  ├─ CompletedFile.swift
│  └─ VideoItem.swift
│
├─ Services/
│  ├─ APIClient.swift
│  ├─ HealthService.swift
│  ├─ CompletedFilesService.swift
│  ├─ VideoService.swift
│  ├─ TorrentService.swift
│  └─ TailscaleHelper.swift
│
├─ ViewModels/
│  ├─ HomeViewModel.swift
│  ├─ VideosViewModel.swift
│  └─ PlayerViewModel.swift
│
├─ Views/
│  ├─ MainTabView.swift
│  ├─ HomeView.swift
│  ├─ DownloaderWebView.swift
│  ├─ VideosView.swift
│  ├─ VideoPlayerView.swift
│  ├─ QBittorrentWebView.swift
│  ├─ FilesWebView.swift
│  └─ SettingsView.swift
│
├─ Components/
│  ├─ WebViewContainer.swift
│  ├─ VideoListRow.swift
│  ├─ ServerStatusCard.swift
│  ├─ EmptyStateView.swift
│  └─ LoadingStateView.swift
│
└─ Player/
   ├─ VLCPlayerView.swift
   ├─ PlayerControlsView.swift
   └─ PlaybackPositionStore.swift
```

---

## 6. Data models

### CompletedFile

```swift
struct CompletedFile: Codable, Identifiable {
    var id: String { fileName }
    let fileName: String
    let displayName: String?
    let streamURL: String?
    let size: Int64?
    let modifiedAt: String?
    let extensionName: String?
}
```

### VideoItem

```swift
struct VideoItem: Codable, Identifiable {
    var id: String { streamURL }
    let fileName: String
    let displayName: String
    let streamURL: String
    let size: Int64?
    let modifiedAt: String?
    let extensionName: String
}
```

---

## 7. Main app navigation

```text
MainTabView
├─ HomeView
├─ DownloaderWebView
├─ VideosView
├─ QBittorrentWebView
└─ FilesWebView
```

Videos flow:

```text
VideosView
→ VideoPlayerView
→ VLCPlayerView internally
```

There is no separate user-facing player engine button.

---

## 8. WebView responsibility

Use one reusable `WebViewContainer`.

It should support:

```text
Load URL
Show loading state
Show connection error
Retry
Stay inside app
```

Use it for:

```text
DownloaderWebView
QBittorrentWebView
FilesWebView
```

---

## 9. API client responsibility

The API client should handle:

```text
GET /api/health
GET /api/torrents
GET /api/completed-files
Future GET /api/videos
```

It should not:

```text
Change backend behavior
Delete files unless user explicitly uses Downloader controls
Expose server publicly
```

---

## 10. Player architecture

```text
VideosView gets video list
→ user selects VideoItem
→ VideoPlayerView receives streamURL
→ VLCPlayerView loads streamURL
→ PlayerControlsView controls playback
→ PlaybackPositionStore saves progress later
```

---

## 11. HTTP / App Transport Security

Current app uses HTTP over private Tailscale IP.

The iOS app may need ATS exception for:

```text
100.92.146.101
```

Keep this private.

Do not expose HTTP ports publicly.

---

## 12. Server architecture must remain

Do not replace:

```text
qBittorrent-nox
FastAPI
Nginx /files/
Static /app/
Tailscale
Oracle Ubuntu
```

The iOS app is only an additional client.
