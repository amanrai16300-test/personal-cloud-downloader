# Personal Cloud Downloader iOS App Direction Lock

Created: 2026-06-01  
Project: Personal Cloud Downloader  
Repo path on Windows: `C:\my space\Projects\cloud_download`  
Access model: Private through Tailscale only  
Legal scope: Legal files only

---

## 1. Purpose

This file is the direction lock for the future private iOS companion app.

It exists to prevent:

- Replacing the current working web downloader by mistake.
- Turning the project into a public torrent app.
- Moving file-management controls into the wrong screen.
- Creating a generic AI-looking app.
- Breaking Oracle/Tailscale private access.
- Changing backend/server behavior without need.
- Forgetting that laptop/PC browser usage must remain supported.

---

## 2. One-line direction

```text
Build a private iOS companion app for the existing Personal Cloud Downloader,
while keeping the current laptop web downloader unchanged.
```

The iOS app should combine:

```text
Existing downloader web UI
+
Clean nPlayer/VLC-style video library
+
qBittorrent Web UI
+
Raw Nginx file browser
+
Tailscale helper access
```

---

## 3. Current live environment

Oracle is the main working environment.

AWS EC2 is stopped to reduce cost.

```text
Oracle Tailscale IP:
100.92.146.101

SSH user:
ubuntu

Windows repo path:
C:\my space\Projects\cloud_download

Private SSH from PC:
ssh -i "$env:USERPROFILE.ssh\oracle-personal-cloud-downloader-key" ubuntu@100.92.146.101
```

---

## 4. Current private URLs

```text
Current downloader web UI:
http://100.92.146.101:8090/app/

Nginx file streaming:
http://100.92.146.101:8090/files/

FastAPI backend:
http://100.92.146.101:8000

Backend health:
http://100.92.146.101:8000/api/health

qBittorrent Web UI:
http://100.92.146.101:8080
```

---

## 5. Current important files

Local repo:

```text
backend/main.py
frontend/index.html
frontend/style.css
frontend/app.js
docs/PROJECT_CONTEXT.md
```

Oracle deployed locations:

```text
Backend:
~/personal-cloud-downloader/backend/main.py

Frontend:
 /var/www/personal-cloud/app/index.html
 /var/www/personal-cloud/app/style.css
 /var/www/personal-cloud/app/app.js

Nginx config:
 /etc/nginx/sites-enabled/personal-cloud
```

---

## 6. Current confirmed working status

Already working:

- Oracle qBittorrent works privately through Tailscale.
- Oracle Nginx `/files/` streaming works.
- VLC stream/download links work.
- FastAPI backend works.
- Static frontend UI is deployed at `/app/`.
- Phone access works after Tailscale is connected.
- Add legal magnet works.
- Progress/status updates work.
- Completed files show only files actually on disk.
- Completed Files hides Screens/images/nfo/txt/sample files.
- Completed Files auto-updates after completion with slight polling delay.
- Stream, Download, Copy VLC link, and Delete work.
- Delete removes torrent/files and clears Completed Files.
- Date/time display exists where available.
- `Time unavailable` fallback exists.

---

## 7. Absolute direction rule

The iOS app must not replace the existing website.

Correct relationship:

```text
Existing web downloader = keep for laptop/PC use
Future iOS app = extra private mobile layer
Same Oracle server = shared backend/storage/streaming source
```

The current web app must remain available at:

```text
http://100.92.146.101:8090/app/
```

---

## 8. Must not change the existing web downloader

Strict rules:

```text
Do not remove /app/.
Do not break laptop/PC browser access.
Do not force all usage into the iOS app.
Do not remove current Stream/Download/Copy/Delete behavior from the web UI.
Do not redesign the existing downloader website unless requested separately.
Do not make the iOS app the only way to use the project.
```

---

## 9. What we are building

One private iOS app:

```text
Personal Cloud iOS App
├─ Home / Dashboard
├─ Downloader
├─ Videos
├─ qBittorrent
├─ Files
└─ Settings / Tailscale Helper
```

Recommended bottom tabs:

```text
[Home] [Downloader] [Videos] [qBittorrent] [Files]
```

Settings can be inside Home as a gear icon.

---

## 10. What we are not building

Do not build:

```text
Public torrent app
Public App Store downloader app
Replacement for Tailscale
Replacement for qBittorrent
Replacement for existing web downloader
Torrent engine running on iPhone
Public file sharing service
Illegal copyrighted media workflow
Big redesign of current laptop UI
```

---

## 11. Correct system flow

```text
User opens iOS app
→ Tailscale must be connected
→ User opens Downloader tab
→ User adds legal magnet through existing web UI
→ Oracle qBittorrent downloads the file
→ Backend detects completed files from disk
→ Nginx exposes final file under /files/
→ Downloader tab shows full management controls
→ Videos tab shows only video files in clean library
→ User taps video
→ Video plays inside the app from Nginx /files/ URL
```

Important:

The app plays from the final file URL.

Correct video source:

```text
http://100.92.146.101:8090/files/<filename>
```

Do not play from:

```text
Original magnet link
qBittorrent internal path
Local iPhone path
Copied VLC button text only
```

---

## 12. Screen responsibility lock

```text
Home = overview and quick access
Downloader = manage downloads/files
Videos = watch videos only
qBittorrent = advanced torrent control
Files = raw file browser
Settings/Tailscale = connection helper
```

Most important separation:

```text
Downloader has file controls.
Videos has watch-only player experience.
```

---

## 13. Downloader responsibility

Downloader keeps:

```text
Add legal magnet link
Active torrent list
Progress/status
Completed Files list
Date/time
Size
Stream / Play button
Download button
Copy VLC link
Delete torrent/files
```

These must not move into Videos:

```text
Date/time
Size
Download
Copy VLC link
Delete
Full completed file controls
```

---

## 14. Videos responsibility

Videos is clean and watch-only.

Videos should show:

```text
Clean video names
Recently added
Continue watching later
Search later
Tap video to play inside app
```

Videos should not show:

```text
Delete button
Copy VLC link
Download button
Raw file browser
Torrent controls
Full file management controls
```

---

## 15. Tailscale rule

Tailscale remains separate.

The app can help by:

```text
Opening Tailscale
Running a Tailscale Shortcut
Showing connection instructions
Opening Downloader after Tailscale
```

The iOS app does not replace Tailscale.

---

## 16. Safety and privacy lock

```text
Legal files only.
Private Tailscale access only.
No public sharing.
No public Oracle ports.
No public torrent/downloader App Store branding.
No illegal copyrighted media workflow.
```

---

## 17. Final confirmed direction

```text
Keep existing web downloader for laptop.
Build private iOS companion app.
Use SwiftUI.
Use WKWebView for existing web panels.
Use native SwiftUI for Home and Videos.
Use VLC-style player engine for wide video support.
Play videos from existing Nginx /files/ links.
Keep Downloader as file management area.
Keep Videos as clean watch-only area.
Keep qBittorrent and Files inside app.
Keep Tailscale separate but helper-accessible.
Use Taste Skill for design creation/redesign.
Use Impeccable for critique/polish/harden.
Private through Tailscale only.
Legal files only.
```
