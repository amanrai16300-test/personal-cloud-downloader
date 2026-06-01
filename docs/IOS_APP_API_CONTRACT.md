# Personal Cloud Downloader iOS App API Contract

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## 1. Purpose

This file defines how the future iOS app should talk to the current FastAPI backend and Nginx file server.

The goal is to avoid breaking the existing downloader.

---

## 2. Base URLs

```text
Backend:
http://100.92.146.101:8000

Nginx app/files:
http://100.92.146.101:8090

qBittorrent:
http://100.92.146.101:8080
```

---

## 3. Existing endpoints

Current backend endpoints:

```text
GET /api/health
GET /api/torrents
GET /api/completed-files
DELETE /api/torrents/{hash}
```

These are enough for early iOS phases.

---

## 4. GET /api/health

Purpose:

```text
Check whether backend is reachable.
```

Used by:

```text
Home screen
Settings/Tailscale helper
Connection error handling
```

Expected use:

```text
GET http://100.92.146.101:8000/api/health
```

iOS behavior:

```text
Success = show server online
Failure = show Tailscale/server connection message
```

Do not expose extra server details unnecessarily.

---

## 5. GET /api/torrents

Purpose:

```text
Show active/current torrent status.
```

Used by:

```text
Home active downloads count
Optional native dashboard status
```

Current backend may return:

```text
name
hash
progress
state/status
added_at
completed_at
```

iOS should treat missing fields safely.

Rules:

```text
Do not depend on qBittorrent always providing added_at/completed_at.
Show fallback if time is unavailable.
```

---

## 6. GET /api/completed-files

Purpose:

```text
Disk-based source of truth for completed files.
```

Used by:

```text
Downloader current web UI
Future Videos tab initial version
Home completed video count
```

Current behavior:

```text
Returns only files actually on disk
Hides Screens/screenshots/sample/nfo/txt/images
Returns real modified_at from server file stat
Supports no-store/cache-busting frontend refresh
```

Downloader use:

```text
Show all useful completed files
```

Videos use:

```text
Filter only video extensions
```

Important:

Do not break this endpoint for the iOS app.

---

## 7. Future GET /api/videos

Optional future endpoint.

Purpose:

```text
Return only video files for native Videos tab.
```

Recommended response:

```json
[
  {
    "file_name": "Movie.Name.2026.mkv",
    "display_name": "Movie Name 2026",
    "stream_url": "http://100.92.146.101:8090/files/Movie.Name.2026.mkv",
    "size": 1480000000,
    "modified_at": "2026-06-01T21:30:00",
    "extension": ".mkv"
  }
]
```

Rules:

```text
Keep /api/completed-files unchanged.
Do not remove non-video completed files from Downloader.
Use /api/videos only for clean video library.
```

---

## 8. DELETE /api/torrents/{hash}

Purpose:

```text
Delete torrent/files.
```

Used by:

```text
Downloader only
```

Important screen rule:

```text
Delete action belongs in Downloader, not Videos.
```

The Videos tab should not expose delete.

---

## 9. Nginx /files/ stream URLs

Video playback should use:

```text
http://100.92.146.101:8090/files/<filename>
```

The iOS player must use the final stream URL from Nginx.

Do not play from:

```text
Original magnet link
qBittorrent internal path
Local iPhone file path
```

---

## 10. HTTP and cache behavior

Current frontend uses:

```text
cache: no-store
?t=Date.now()
```

iOS API calls should also avoid stale video lists where necessary.

Recommended behavior:

```text
Refresh Videos when tab appears
Allow manual refresh
Do not aggressively poll in background
```

---

## 11. Error handling

For failed API calls, show clear messages:

```text
Server not reachable.
Connect Tailscale and try again.

Backend is offline.
Check personal-downloader-api service.

Files not reachable.
Check Nginx /files/ and Tailscale.
```

Do not show scary technical errors as the main UI.

---

## 12. iOS model mapping

### VideoItem

```text
file_name -> original server file name
display_name -> clean name for UI
stream_url -> full /files/ playable URL
size -> optional
modified_at -> optional
extension -> file extension
```

### CompletedFile

Used for full file list in Downloader or future native management.

---

## 13. Security/API rules

```text
Private Tailscale only.
Do not expose API publicly.
Do not add public CORS/public access for iOS.
Do not add auth unless access ever goes beyond Tailscale.
Do not log sensitive magnet links in UI.
Legal files only.
```

---

## 14. Phase 2 Videos library status (native milestone)

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

## 15. Phase 3 player core status (player milestone)

```text
Phase 3 player core is complete.
PlayerView was added as the dedicated video player route.
VideosView now navigates to PlayerView using NavigationLink / navigationDestination.
CompletedFile now supports Hashable and streamURL resolution.
backend/main.py was read-only only to confirm CompletedFile.url is generated as a stream link; not modified.
Deployed CompletedFile.url is an absolute, percent-encoded Nginx /files/ URL: http://100.92.146.101:8090/files/...
The iOS player sources playback from CompletedFile.url (the Nginx /files/ stream link), not magnet, qBittorrent path, or local path.
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
