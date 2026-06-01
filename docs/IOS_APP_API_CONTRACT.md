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
