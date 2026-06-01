# Personal Cloud Downloader iOS App Checklists

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## 1. Direction checklist

Before coding, confirm:

```text
Existing web downloader remains available at /app/
iOS app is an extra layer
Oracle remains downloader/storage/streaming server
Tailscale remains private access layer
qBittorrent remains the torrent engine
iPhone does not run torrent downloading locally
Legal files only
```

---

## 2. Screen responsibility checklist

```text
Home = overview and quick actions
Downloader = file/download management
Videos = watch-only media library/player
qBittorrent = advanced torrent control
Files = raw file browser
Settings = Tailscale/server helper
```

Reject any change that mixes these responsibilities without a clear reason.

---

## 3. Downloader checklist

Downloader must keep:

```text
Add legal magnet
Active torrent progress
Completed Files list
Date/time
Size
Stream / Play
Download
Copy VLC link
Delete
```

Downloader must not:

```text
Lose current web functionality
Break laptop/PC usage
Require iOS app only
```

---

## 4. Videos checklist

Videos must show:

```text
Clean video names
Only video files
Tap to play
Watch-only UI
```

Videos must not show:

```text
Delete
Download
Copy link
Torrent controls
Raw files browser layout
```

---

## 5. Video playback checklist

Video must play from:

```text
http://100.92.146.101:8090/files/<filename>
```

Not from:

```text
Magnet link
qBittorrent internal path
Local iPhone path
Clipboard-only value
```

---

## 6. iOS technical checklist

Use:

```text
Swift
SwiftUI
Xcode
WKWebView
URLSession + async/await
Codable
AppStorage/UserDefaults
MobileVLCKit/VLC-style engine later
```

Avoid first:

```text
React Native
Flutter
Capacitor
Torrent engine on iPhone
Public App Store release
```

Capacitor is not forbidden forever, but SwiftUI is the recommended first path.

---

## 7. WebView checklist

WebView screens:

```text
Downloader -> http://100.92.146.101:8090/app/
qBittorrent -> http://100.92.146.101:8080
Files -> http://100.92.146.101:8090/files/
```

Each should:

```text
Stay inside app
Show loading state
Show retry/error state
Not open Safari unless explicitly required
```

---

## 8. Tailscale checklist

Before using app:

```text
Tailscale connected on iPhone
Oracle server reachable
Backend health works
Nginx /files/ works
qBittorrent UI works
```

App should show:

```text
Connect Tailscale first
```

when URLs fail.

---

## 9. API checklist

Current endpoints:

```text
GET /api/health
GET /api/torrents
GET /api/completed-files
DELETE /api/torrents/{hash}
```

Future optional:

```text
GET /api/videos
```

Do not break:

```text
/api/completed-files
delete behavior
current frontend polling
current file filtering
```

---

## 10. Design checklist

Good design should feel:

```text
Private
Modern
Calm
Premium
Utility-focused
Mobile-first
Media-friendly
```

Bad design signs:

```text
Generic AI dashboard
Too many gradients
Too many glowing cards
Random icons
Bad spacing
Tiny tap targets
Delete buttons in Videos
Crowded cards
Poor long filename handling
```

---

## 11. Taste Skill checklist

Use Taste Skill when:

```text
Creating a new screen
Redesigning a screen
Improving visual direction
Making UI less generic
```

Do not use it to:

```text
Change backend behavior
Change architecture
Break screen responsibilities
Redesign everything at once
```

---

## 12. Impeccable checklist

Use Impeccable when:

```text
A screen already exists
You need critique
You need polish
You need hardening
You want to remove generic AI look
```

Fix only:

```text
Top 3 problems at a time
```

---

## 13. Safety checklist

Do not:

```text
Expose Oracle ports publicly
Open API to the internet
Remove Tailscale-only model
Use this for illegal copyrighted media
Brand this as a public torrent app
Make public sharing features
```

---

## 14. Before accepting any AI change

Ask:

```text
Did it touch only the intended file/screen?
Did it keep existing web downloader working?
Did it keep Downloader and Videos separate?
Did it avoid public exposure?
Did it avoid unrelated improvements?
Did it follow the stack?
Did it follow the design system?
```

If no, reject or ask for a smaller fix.

---

## 15. Final project safety sentence

```text
This is a private legal-files-only cloud downloader and iOS companion player,
not a public torrent/downloader platform.
```
