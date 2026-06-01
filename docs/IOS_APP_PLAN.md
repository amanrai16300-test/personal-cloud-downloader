# Personal Cloud Downloader iOS App Plan

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## 1. Goal

Build a private iOS companion app for the existing Oracle/Tailscale Personal Cloud Downloader.

The app should combine:

```text
Home dashboard
Downloader web panel
Clean video library/player
qBittorrent web panel
Files web panel
Tailscale helper/settings
```

The current web downloader must remain unchanged for laptop/PC use.

---

## 2. Final app layout

Bottom tabs:

```text
[Home] [Downloader] [Videos] [qBittorrent] [Files]
```

Settings lives inside Home.

---

## 3. Home

Purpose:

```text
Quick overview of server and app status.
```

Home should show:

```text
Server online/offline
Tailscale reminder
Active downloads count
Completed videos count
Quick buttons
```

Quick buttons:

```text
Open Downloader
Open Videos
Open qBittorrent
Open Files
Open Tailscale
Refresh status
```

Home calls:

```text
GET /api/health
GET /api/torrents
GET /api/completed-files
```

---

## 4. Downloader

Purpose:

```text
Manage downloads and completed files.
```

Phase 1 implementation:

```text
WKWebView loading:
http://100.92.146.101:8090/app/
```

Downloader keeps:

```text
Add legal magnet
Active download progress
Completed Files list
Date/time
Size
Stream / Play
Download
Copy VLC link
Delete torrent/files
```

Do not remove the browser version.

Do not redesign the existing web downloader unless requested separately.

---

## 5. Videos

Purpose:

```text
Clean nPlayer/VLC-style watch-only video library.
```

Videos should show:

```text
Clean video names
Recently added
Continue watching later
Search later
Tap to play inside app
```

Videos should not show:

```text
Delete
Copy link
Download
Raw file browser controls
Torrent controls
```

Initial data source:

```text
GET /api/completed-files
```

Future clean source:

```text
GET /api/videos
```

Supported initial video extensions:

```text
.mp4
.mkv
.avi
.mov
.webm
.m4v
```

---

## 6. Video player

Purpose:

```text
Play completed videos from Oracle Nginx /files/ links.
```

Correct playback source:

```text
http://100.92.146.101:8090/files/<filename>
```

The player should not use:

```text
Original magnet link
qBittorrent internal path
Local iPhone path
```

Player features by phase:

### First version

```text
Open video from URL
Play/pause
Seek
Full screen
Back button
```

### Later

```text
Resume position
Recently watched
Forward/back 10 seconds
Playback speed
Subtitle selection
Audio track selection
Fit/fill/crop
Lock controls
```

Player design can be nPlayer/VLC-style, but not copied exactly.

---

## 7. qBittorrent

Purpose:

```text
Advanced torrent control.
```

Use WKWebView:

```text
http://100.92.146.101:8080
```

Do not rebuild qBittorrent natively in Phase 1.

---

## 8. Files

Purpose:

```text
Raw file browser.
```

Use WKWebView:

```text
http://100.92.146.101:8090/files/
```

Files is not the same as Videos.

```text
Videos = clean media library
Files = raw server file browser
```

---

## 9. Settings / Tailscale Helper

Tailscale remains separate.

Settings can include:

```text
Server IP
Backend URL
Open Tailscale
Run Tailscale Shortcut
Connection help
```

If connection fails, show:

```text
Connect Tailscale first, then reopen this screen.
```

---

## 10. Development phases summary

```text
Phase 0 = Documentation lock
Phase 1 = Basic SwiftUI shell + web panels
Phase 2 = Native Videos library
Phase 3 = VLC-style player integration
Phase 4 = Better media features
Phase 5 = Optional /api/videos endpoint
Phase 6 = Taste Skill + Impeccable design polish
```

---

## 11. Main must-not-change rules

```text
Do not expose Oracle publicly.
Do not remove Tailscale-only private design.
Do not replace qBittorrent.
Do not run torrent downloading on iPhone.
Do not remove or break /app/.
Do not remove laptop/PC browser usage.
Do not move file management controls into Videos.
Do not make Videos a raw file manager.
Legal files only.
```
