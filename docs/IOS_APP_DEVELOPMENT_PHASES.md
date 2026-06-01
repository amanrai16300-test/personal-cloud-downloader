# Personal Cloud Downloader iOS App Development Phases

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## Phase 0: Documentation lock

Goal:

```text
Create the docs before coding.
```

Tasks:

```text
Add docs/IOS_APP_DIRECTION_LOCK.md
Add docs/IOS_APP_PLAN.md
Add docs/IOS_APP_ARCHITECTURE.md
Add docs/IOS_APP_DESIGN_SYSTEM.md
Add docs/IOS_APP_DEVELOPMENT_PHASES.md
Add docs/IOS_APP_API_CONTRACT.md
Add docs/IOS_APP_AI_PROMPTS.md
Add docs/IOS_APP_CHECKLISTS.md
Update docs/PROJECT_CONTEXT.md with short summary only
```

Do not change:

```text
Backend
Frontend
Nginx
Systemd services
Oracle server config
```

---

## Phase 1: Basic iOS app shell

Goal:

```text
Create the first private iOS app shell.
```

Stack:

```text
Swift
SwiftUI
Xcode
WKWebView
URLSession
Codable
```

Screens:

```text
Home
Downloader
Videos placeholder
qBittorrent
Files
Settings/Tailscale helper
```

Requirements:

```text
Home checks /api/health
Downloader opens /app/ inside app
qBittorrent opens :8080 inside app
Files opens /files/ inside app
Videos is placeholder only
URLs are stored in one config file
Private HTTP access allowed only for Tailscale IP if needed
```

Do not implement:

```text
Native video player
Torrent downloading on iPhone
Backend changes
Existing web UI redesign
```

---

## Phase 2: Native video library

Goal:

```text
Create a real Videos tab.
```

Tasks:

```text
Call GET /api/completed-files
Filter video extensions
Show clean video names
Show recently added
Open selected video in simple player screen
```

Video extensions:

```text
.mp4
.mkv
.avi
.mov
.webm
.m4v
```

Do not add:

```text
Delete
Copy link
Download
Raw file browser controls
```

---

## Phase 3: VLC-style player integration

Goal:

```text
Make video playback closer to nPlayer/VLC.
```

Stack:

```text
MobileVLCKit / VLC-style player engine
SwiftUI wrapper
Custom player controls
```

Tasks:

```text
Play videos from Nginx /files/ links
Support common formats if possible
Add play/pause
Add seek
Add full screen
Add forward/back 10 seconds
Add basic error state
```

Do not:

```text
Copy nPlayer UI exactly
Use VLC branding
Use VLC cone branding
Make player engine a separate user-facing tab
```

---

## Phase 4: Better video experience

Goal:

```text
Improve media-player feel.
```

Tasks:

```text
Resume playback position
Continue watching section
Recently watched section
Search videos
Sort by recently added/name
Playback speed
Subtitle selection
Audio track selection
Fit/fill/crop
Lock controls
```

Local storage:

```text
AppStorage or UserDefaults
```

---

## Phase 5: Optional backend refinement

Goal:

```text
Add a clean video-only API if needed.
```

Add:

```text
GET /api/videos
```

Return:

```text
file_name
display_name
stream_url
size
modified_at
extension
```

Rules:

```text
Do not break /api/completed-files
Do not change Downloader behavior
Do not remove non-video completed files from Downloader
```

---

## Phase 6: Design polish

Goal:

```text
Make it professional, not generic AI design.
```

Workflow per screen:

```text
Use Taste Skill for screen design direction
Build/update one screen only
Use Impeccable critique
Fix top 3 design issues only
Use Impeccable polish/harden if needed
Move to next screen
```

Screen order:

```text
Home
Videos
Video Player
Settings/Tailscale
Downloader wrapper
qBittorrent wrapper
Files wrapper
```

---

## Phase 7: Safety and stability pass

Goal:

```text
Make sure the app respects the project rules.
```

Check:

```text
Existing web downloader still works from laptop
No public port exposure
Tailscale-only private access
No torrent engine on iPhone
Videos is watch-only
Downloader keeps file controls
qBittorrent and Files stay inside app
Legal-files-only wording remains
```

---

## What to avoid in every phase

```text
Do not change multiple major areas at once.
Do not redesign current web downloader without specific request.
Do not add public access.
Do not add authentication unless going beyond Tailscale.
Do not touch Oracle services unless needed.
Do not create giant app-wide redesign.
Do not let AI “check everything.”
```
