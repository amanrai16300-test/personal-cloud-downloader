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

### Phase 1 Status (web panel milestone)

```text
iOS app work is on branch feature/ios-companion-app.
iOS source created under ios/PersonalCloudDownloader/.
XcodeGen setup added with project.yml.
Generated files ignored: ios/PersonalCloudDownloader.xcodeproj/ and ios/PersonalCloudDownloader/Info.plist.
SwiftUI app shell exists with TabView.
Tabs: Home, Downloader, Videos, qBittorrent, Files, Settings.
Reusable WKWebView support added: WebView and WebScreen.
ATS HTTP loading support added for private Tailscale URLs.
Downloader tab loads http://100.92.146.101:8090/app/
qBittorrent tab loads http://100.92.146.101:8080
Files tab loads http://100.92.146.101:8090/files/
Home, Videos, and Settings are still placeholders.
No backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale behavior changed.
Existing browser web downloader remains the main working app.
```

### Phase 1 Status (Home and Settings native milestone)

```text
Home tab is now a native SwiftUI dashboard.
Home shows app title, private cloud downloader subtitle, Tailscale connection reminder, Oracle server IP, screen guide, and safety note.
Settings tab is now a native SwiftUI Settings / Tailscale Helper screen.
Settings shows server URLs, Tailscale-only privacy note, and Open Tailscale helper button using tailscale://.
Downloader, qBittorrent, and Files remain WKWebView tabs.
Videos is still only a placeholder.
No video player, API integration, torrent logic, backend change, frontend web app change, Oracle change, Nginx change, qBittorrent change, or Tailscale change was made.
Existing browser web downloader remains unchanged and usable.
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

### Phase 2 Status (native Videos library milestone)

```text
Phase 2 native Videos library was added.
Videos tab fetches from http://100.92.146.101:8000/api/completed-files
CompletedFile model matches real backend keys: name, path, url, modified_at.
backend/main.py was read-only only to confirm JSON field names.
backend/main.py was not modified.
Videos filters video files client-side by extension: mp4, mov, m4v, mkv, avi, webm.
Videos screen has loading, error with retry, empty state, list state, and pull-to-refresh.
Video rows show title and modified date when available.
Size is not shown because /api/completed-files currently does not return size.
Tapping a video currently shows "Video player will be added later."
No playback was added yet.
No AVPlayer, MobileVLCKit, /api/videos, delete, download, copy link, torrent logic, backend change, frontend web app change, Oracle change, Nginx change, qBittorrent change, or Tailscale change was made.
Videos remains a clean video library, not a file manager.
code-review-graph is only development tooling, not app runtime.
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

### Phase 3 Status (player core milestone)

```text
Phase 3 player core is complete.
PlayerView was added as the dedicated video player route.
VideosView now navigates to PlayerView using NavigationLink / navigationDestination.
CompletedFile now supports Hashable and streamURL resolution.
backend/main.py was read-only only to confirm CompletedFile.url is generated as a stream link; not modified.
Deployed CompletedFile.url is an absolute, percent-encoded Nginx /files/ URL: http://100.92.146.101:8090/files/...
AVPlayer / AVKit playback was added for mp4, mov, m4v.
MobileVLCKit dependency setup was added with CocoaPods: ios/Podfile, pod 'MobileVLCKit', '~> 3.6.0'.
CocoaPods generated files are ignored: ios/Pods/ and ios/PersonalCloudDownloader.xcworkspace/.
Podfile.lock should be committed after pod install creates it.
VLCPlayerView was added for VLC playback.
VLC engine is used for mkv, avi, webm.
VLCPlayerController owns VLCMediaPlayer and manages playback state.
VLC playback supports auto-play on open, stop on leave, play/pause, progress/time display, seek slider, and forward/back 10 second skip.
AVPlayer branch remains intact.
Videos remains a clean video library/player, not a file manager.
No Delete, Download, or Copy Link controls were added to Videos.
No backend endpoint changes were made.
No /api/videos endpoint was created.
No frontend web app, Oracle, Nginx, qBittorrent, or Tailscale behavior was changed.
Existing web downloader remains unchanged and usable.
Fullscreen, rotation, and error-state polish are not complete yet.
```

### Phase 3 Status (player polish state-handling milestone)

```text
Player Polish state handling was added after the Phase 3 player core.
VLC branch now has user-friendly playback states: loading/buffering, ready, failed, ended.
VLC branch UI: buffering spinner, playback-failed overlay with Retry, ended overlay with Replay.
VLC play/pause, seek slider, forward/back 10 second skip, auto-play on open, and stop-on-leave remain intact.
AVPlayer branch now has basic state handling too: loading, ready, failed, ended.
AVPlayer branch keeps the system VideoPlayer controls.
AVPlayer ended state shows Replay and auto-dismisses if playback resumes from the system controls.
AVPlayer failed state shows Retry.
VLC branch was not changed during the AVPlayer state work.
Videos list was not changed.
No backend, frontend web app, Oracle, Nginx, qBittorrent, Tailscale, or API endpoint behavior was changed.
No Delete, Download, or Copy Link controls were added to Videos.
Fullscreen and rotation are still not complete.
```

### Phase 3 Status (player polish fullscreen and orientation decision milestone)

```text
Player Polish fullscreen mode was added.
PlayerView now has fullscreen support using fullScreenCover.
Fullscreen works for both the AVPlayer branch and the VLC branch.
Inline and fullscreen player UI share extracted reusable player subviews.
AVPlayer branch keeps mp4, mov, m4v behavior.
VLC branch keeps mkv, avi, webm behavior.
VLC play/pause, seek slider, forward/back 10 second skip, and loading/error/ended overlays remain intact.
VLC drawable handling was improved so the player can reclaim the drawable when switching between inline and fullscreen.
Orientation setup was inspected.
ios/project.yml has no explicit orientation keys.
The app already supports landscape by default.
No forced rotation code was added.
No app-wide orientation settings were changed.
Decision: use zero-config orientation for now. The user can rotate the device manually in fullscreen.
Forced auto-landscape rotation is intentionally deferred because it requires UIKit/app-wide orientation handling and has SwiftUI risk.
No backend, frontend web app, Videos list, Oracle, Nginx, qBittorrent, Tailscale, or API behavior was changed.
No Delete, Download, or Copy Link controls were added to Videos.
```

### Phase 3 Status (player polish UI milestone)

```text
Player Polish UI step was completed.
Only PlayerView layout/modifiers were changed.
Player screen spacing was cleaned up with shared layout constants.
Title area was improved with clearer hierarchy and tighter grouping.
Inline player surface now has rounded corners and a subtle hairline border.
Fullscreen player remains full-bleed and square.
Fullscreen button placement and tap target were improved.
VLC controls were visually reorganized:
- slider/time group above
- transport controls below
- larger play/pause button
- consistent skip button tap targets
Time/progress spacing was aligned.
AV and VLC overlay UI was deduplicated for consistent loading, failed, and ended states.
Error and ended overlays were visually clarified.
URL caption was made less distracting.
AVPlayer logic was not changed.
VLC logic was not changed.
Fullscreen behavior was not changed.
Zero-config orientation decision was not changed.
Videos list was not changed.
No backend, frontend web app, Oracle, Nginx, qBittorrent, Tailscale, or API behavior was changed.
No Delete, Download, or Copy Link controls were added to Videos.
Build was not verified yet because the current environment is Windows without Xcode.
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
