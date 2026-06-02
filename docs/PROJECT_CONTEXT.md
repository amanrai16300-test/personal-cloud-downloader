# Personal Cloud Downloader Project Context

## 1. Project Overview

- Project name: Personal Cloud Downloader
- Goal: Build a private personal cloud downloader, similar to a small Seedr-style tool, for legal files only.
- Main use case: Download files on a cloud server, then stream or download them privately from a browser, VLC, iPhone, or Windows.
- Download size rule: Keep downloads under 10GB.
- Retention rule: Delete downloaded files quickly after use.
- Privacy rule: qBittorrent, file streaming, and any future backend should stay private through Tailscale.

## 2. Current AWS Working Setup

- Current working cloud provider: AWS
- AWS region: Asia Pacific Tokyo, `ap-northeast-1`
- Instance name: `personal-cloud-downloader`
- Instance ID: `i-022a0df7a98e5883c`
- OS: Ubuntu Server 24.04 LTS
- Current access method: private SSH through Tailscale
- Working private SSH:

```powershell
ssh -i .\personal-cloud-downloader-key.pem ubuntu@100.125.15.118
```

- Old public SSH:

```powershell
ssh -i .\personal-cloud-downloader-key.pem ubuntu@43.206.111.90
```

- Windows project folder:

```text
C:\my space\backup\Portfolio\cloud download service
```

## 3. AWS Server Details

- Public IPv4: `43.206.111.90`
- Private IPv4: `172.31.11.141`
- Instance type: `t3.micro`
- Storage: 30 GiB gp3
- SSH user: `ubuntu`
- Key pair file: `personal-cloud-downloader-key.pem`
- Security group name: `launch-wizard-2`
- Security group ID: `sg-0217c5c04134315e7`
- Completed downloads folder:

```text
/srv/personal-cloud/downloads/complete
```

- Incomplete downloads folder:

```text
/srv/personal-cloud/downloads/incomplete
```

## 4. Tailscale Private Network

- Server Tailscale IP: `100.125.15.118`
- Tailscale is required for private access from Windows and iPhone.
- Main access should be Tailscale SSH.
- qBittorrent, Nginx streaming, and any future backend must stay private through Tailscale.
- Private services should bind to the server and be reachable only through Tailscale firewall rules.

## 5. qBittorrent Setup

- qBittorrent Web UI private URL:

```text
http://100.125.15.118:8080
```

- Completed downloads:

```text
/srv/personal-cloud/downloads/complete
```

- Incomplete downloads:

```text
/srv/personal-cloud/downloads/incomplete
```

- Usage rules:
  - Use only for legal files.
  - Keep downloads under 10GB.
  - Pause or remove torrents after downloads finish.
  - Avoid seeding unless intentionally needed.
  - Delete completed files quickly after streaming or downloading.

## 6. Nginx Private File Streaming

- File streaming private URL:

```text
http://100.125.15.118:8090/files/
```

- Nginx serves files from:

```text
/srv/personal-cloud/downloads/complete
```

- Access should remain private through Tailscale.
- Do not expose file streaming publicly on AWS.
- Port `8090` should not be open to the public internet.

## 7. iPhone / VLC Usage Flow

- Connect the iPhone to Tailscale.
- Download legal file on the AWS server through qBittorrent Web UI:

```text
http://100.125.15.118:8080
```

- After the download completes, open the private file listing:

```text
http://100.125.15.118:8090/files/
```

- Stream from browser or copy the file URL into VLC.
- After viewing, delete the file from the server quickly.
- Keep total file sizes small to reduce AWS outbound data transfer.

## 8. Security Rules

- Do not open public AWS ports `8080`, `8090`, or `8000`.
- Public SSH was temporarily opened during setup but should not be left at `0.0.0.0/0`.
- Temporary public SSH backup used carrier range `133.106.0.0/16` because `/32` did not work.
- Main access should be Tailscale SSH:

```powershell
ssh -i .\personal-cloud-downloader-key.pem ubuntu@100.125.15.118
```

- UFW should allow `22`, `8080`, and `8090` only on `tailscale0`.
- UFW may optionally allow temporary public SSH backup from `133.106.0.0/16`.
- Do not store private keys, API private keys, PEM contents, or secret values in this repo.
- qBittorrent, Nginx streaming, and future backend services should stay private through Tailscale.

## 9. Cost and Data Transfer Notes

- AWS metric to watch: `NetworkOut`.
- Data going out from AWS to iPhone, Windows, browser, or VLC counts as outbound data transfer.
- qBittorrent seeding and uploads also increase `NetworkOut`.
- Keep usage small.
- Pause or remove torrents after download.
- Delete files quickly after use.
- Current AWS email showed `$89` credits remaining.
- Estimated post-free AWS cost for this downloader if running 24/7: about `$16` to `$18` per month.
- Stopping EC2 when not using it reduces compute cost.

## 10. Oracle Cloud Always Free Plan

- Goal: Move to Oracle Always Free after full testing succeeds.
- Region/home region: Japan East Tokyo
- Shape: `VM.Standard.A1.Flex`
- OCPU: `2`
- RAM: `4GB`
- Boot volume: `100GB`
- OS: Ubuntu 24.04
- VCN: `personal-cloud-downloader-vcn`
- Subnet: `personal-cloud-downloader-public-subnet`
- VNIC: `personal-cloud-downloader-vnic`
- Instance name: `personal-cloud-downloader`
- Oracle A1 instance was successfully created.
- Public IP: `138.2.31.123`
- Private IP: `10.0.0.58`
- Oracle Tailscale IP: `100.92.146.101`
- SSH user: `ubuntu`
- Main private SSH through Tailscale:

```powershell
ssh -i "$env:USERPROFILE\.ssh\oracle-personal-cloud-downloader-key" ubuntu@100.92.146.101
```

## 11. Oracle OCI CLI Retry Script Status

- OCI CLI is installed on Windows.
- OCI CLI version: `3.84.0`
- API key was added successfully.
- Retry script file:

```text
oracle-a1-retry.ps1
```

- Retry script currently works and returns:

```text
Reason: Oracle A1 capacity not available yet. Waiting 30 minutes before retry.
```

- Recommended retry interval: 60 minutes.
- Avoid aggressive retry.
- Oracle instance has now been created, so retry script is no longer the active path unless another instance is needed later.

## 12. Phase 1 Backend Progress

- FastAPI backend exists in `backend/`.
- Backend dependencies installed successfully.
- Local Windows test uses real repo path:

```text
C:\my space\Projects\cloud_download
```

- Real `.env` is created at `backend/.env`.
- `backend/.env` is ignored by Git.
- `.env.example` exists at:

```text
backend/.env.example
```

- Current AWS qBittorrent is reached through Tailscale:

```env
QB_URL=http://100.125.15.118:8080
```

- Current AWS Nginx file streaming is reached through Tailscale:

```env
STREAM_BASE_URL=http://100.125.15.118:8090/files
```

- qBittorrent, Nginx, AWS access, and backend app access must remain private through Tailscale only.

### Backend Endpoints Tested

- `GET /api/health` works.
- `GET /api/qbittorrent/test` works.
- `POST /api/add-magnet` works.
- `GET /api/torrents` works and returns simple Seedr-style fields.
- `DELETE /api/torrents/{hash}` works.

Simple torrent fields currently returned:

- `hash`
- `name`
- `status`
- `progress_percent`
- `size`
- `download_speed`
- `eta`
- `is_complete`

### Confirmed Backend Behavior

- New torrents download successfully.
- After download completion, backend background monitor auto-pauses the torrent within about 15 seconds.
- Seeding stops automatically after completion.
- Completed torrent `eta` is normalized to `0`.
- Delete endpoint removes the torrent entry and downloaded files from disk using qBittorrent delete with files.
- Files are not deleted automatically after completion.
- Files are deleted only when the user calls the delete endpoint.

### Changed Backend Files From Phase 1

- `backend/settings.py`
- `backend/qb_client.py`
- `backend/main.py`
- `backend/.env.example`

Latest specific backend fix:

- `backend/main.py` now has a FastAPI startup background monitor.
- The monitor polls qBittorrent every 15 seconds.
- It auto-pauses completed, uploading, and seeding torrents when `AUTO_PAUSE_ON_COMPLETE=true`.
- `/api/torrents` still keeps auto-pause backup behavior.

### Current Test Result

- Health check: OK
- qBittorrent login test: OK
- Add magnet: OK
- Torrent list: OK
- Auto-stop seeding: OK
- Delete torrent and disk files: OK

### Known Issue / Cleanup Note

- Nginx `/files/` listing showed weird path-like folders such as:

```text
\
\srv/
\srv\personal-cloud/
\srv\personal-cloud\downloads/
\srv\personal-cloud\downloads\complete/
```

- Do not delete these from browser.
- Before cleanup, inspect safely through SSH:

```bash
ls -la /srv/personal-cloud/downloads/complete
```

- This is a later cleanup task, not part of Phase 1 backend completion.

## 13. Oracle Migration Status

- Oracle A1 instance was successfully created.
- Oracle is now the confirmed working main environment for the downloader.
- Instance name: `personal-cloud-downloader`
- Shape: `VM.Standard.A1.Flex`
- OCPU: `2`
- RAM: `4GB`
- Public IP: `138.2.31.123`
- Private IP: `10.0.0.58`
- Oracle Tailscale IP: `100.92.146.101`
- SSH user: `ubuntu`
- Main private SSH works through Tailscale:

```powershell
ssh -i "$env:USERPROFILE\.ssh\oracle-personal-cloud-downloader-key" ubuntu@100.92.146.101
```

### Completed Oracle Setup

- Boot volume resized from about 47GB to 100GB.
- Linux partition/filesystem expanded successfully.
- Root filesystem now shows about 96GB total.
- 2GB swap file added and persisted in `/etc/fstab`.
- Ubuntu updated and rebooted successfully.
- Tailscale installed and connected.
- qBittorrent-nox installed.
- qBittorrent Web UI works privately:

```text
http://100.92.146.101:8080
```

- qBittorrent password was changed from the temporary password.
- qBittorrent download paths were set to:

```text
Completed: /srv/personal-cloud/downloads/complete
Incomplete: /srv/personal-cloud/downloads/incomplete
```

- qBittorrent systemd service was created and is running.
- Nginx installed and configured for private file streaming.
- Oracle Nginx file streaming works:

```text
http://100.92.146.101:8090/files/
```

- UFW installed and enabled.
- UFW allows only Tailscale interface access for:
  - `22/tcp`
  - `8080/tcp`
  - `8090/tcp`
  - `8000/tcp`
- Tailscale SSH, qBittorrent, and Nginx file list were tested and confirmed working.
- FastAPI backend was deployed on Oracle as a private systemd service:

```text
http://100.92.146.101:8000
```

- Oracle FastAPI backend end-to-end test passed.
- Legal Big Buck Bunny test magnet was added through `POST /api/add-magnet`.
- Test torrent appeared in `GET /api/torrents`.
- Download completed to `100%`.
- Backend auto-paused the completed torrent.
- Seeding stopped after completion.
- `GET /api/completed-files` showed completed files.
- `HEAD /files/Big Buck Bunny/Big Buck Bunny.mp4` returned `200`.
- `DELETE /api/torrents/{hash}` removed the torrent and downloaded files.
- Final `GET /api/torrents` showed the test torrent was removed.
- Final `GET /api/completed-files` showed the test files were removed.
- Final file `HEAD` returned `404`.

### Oracle Security Notes

- Do not expose qBittorrent, Nginx streaming, or future FastAPI port publicly.
- Keep Oracle access through Tailscale.
- Do not paste or commit passwords, private keys, PEM files, or secret values.
- Oracle Cloud budget alert was created.
- Budget name: `personal-cloud-budget`
- Budget amount: `US$1` monthly
- Budget status: Active
- Budget scope: Oracle compartment/root compartment used for the Personal Cloud Downloader project.
- Budget alert rules created:
  - `50% Actual Spend`
  - `100% Actual Spend`
  - `100% Forecast Spend`
- Budget alerts are email warnings only.
- Budget alerts do not automatically stop or delete Oracle resources.
- AWS EC2 instance has now been stopped to reduce cost.
- AWS should not be used unless needed as backup.

### AWS Backup Status

- AWS downloader still exists, but the EC2 instance has been stopped to reduce cost.
- AWS should not be used unless needed as backup.
- AWS Tailscale IP is still `100.125.15.118`.
- AWS qBittorrent and Nginx were already working.

## 14. Current Final Status

- Oracle is now the confirmed working main environment.
- AWS EC2 instance is stopped and should not be used unless needed as backup.
- Oracle budget alert is active.
- Main cost-warning protection is now done.
- Oracle server is created and downloader services are working through Tailscale.
- Private SSH through Tailscale works.
- AWS backup services existed previously, but AWS is stopped and not the active environment.
- Oracle qBittorrent Web UI works privately through Tailscale:

```text
http://100.92.146.101:8080
```

- Oracle Nginx private file streaming works:

```text
http://100.92.146.101:8090/files/
```

- Oracle FastAPI backend is live privately through Tailscale:

```text
http://100.92.146.101:8000
```

- Private frontend UI is live through Oracle Nginx:

```text
http://100.92.146.101:8090/app/
```

- Downloads are stored under `/srv/personal-cloud/downloads`.
- Phase 1 FastAPI backend is working on Oracle.
- UI can add legal magnet links, show progress, show completed files, stream/download files, copy VLC links, and delete torrent/files.
- Completed Files uses only `GET /api/completed-files`.
- Completed Files shows only files actually on disk.
- Completed Files filters support/extra files such as `Screens/`, images, `.nfo`, `.txt`, and sample files.
- Completed Files auto-updates after completion with a short polling delay.
- Copy VLC link works over HTTP/Tailscale using a clipboard fallback.
- Delete removes torrent/files and clears Completed Files correctly.
- Date/time display was added where available.
- If real time data is unavailable, the UI shows `Time unavailable.`
- Completed Files may update after a short polling delay. This is acceptable for now.
- Backend can add magnets, list simple torrent status, auto-stop seeding, and delete torrents plus disk files when requested.
- AWS was stopped to reduce cost.
- Oracle migration backend testing is complete.
- Simple Seedr-style UI MVP is live on Oracle.

## 15. Next Steps

- Keep AWS services private through Tailscale.
- Confirm AWS public SSH is not left open to `0.0.0.0/0`.
- Continue using Tailscale SSH as the main admin path.
- Keep AWS stopped unless needed as backup.
- Pause or remove torrents after completion.
- Delete completed files quickly.
- Keep local `backend/.env` pointed at Oracle values:

```env
QB_URL=http://100.92.146.101:8080
STREAM_BASE_URL=http://100.92.146.101:8090/files
```

- Keep future backend access private through Tailscale, including any service on port `8000`.
- Continue real phone testing against the live UI.
- Optional: polish the UI after more real phone testing.
- Optional: reduce polling delay later if needed.
- Optional: add authentication only if access ever goes beyond Tailscale.

# PROJECT_CONTEXT.md iOS App Update Snippet

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

Copy this section into:

```text
docs/PROJECT_CONTEXT.md
```

Do not replace the whole file.

---

```md
## iOS App Direction

A future private iOS companion app is planned for the Personal Cloud Downloader.

Direction:
- Existing web downloader at `/app/` must remain unchanged and usable from laptop/PC.
- The iOS app is an extra mobile layer, not a replacement.
- App sections: Home, Downloader, Videos, qBittorrent, Files, Settings/Tailscale helper.
- Downloader keeps full file/download management controls: add magnet, progress, completed files, date/time, size, stream/download, copy VLC link, delete.
- Videos is only a clean nPlayer/VLC-style video library and player.
- Videos should play from the existing Nginx `/files/` streaming links.
- qBittorrent and Files open inside the app through web views.
- Tailscale remains separate, with app helper/shortcut only.
- Oracle remains the downloader/storage/streaming server.
- iPhone must not run torrent downloading locally.
- Use SwiftUI, WKWebView, URLSession/Codable, and later MobileVLCKit/VLC-style player.
- Use Taste Skill for design creation/redesign guidance.
- Use Impeccable for design critique/polish/harden.
- Keep everything private through Tailscale and legal-files-only.

Full docs:
- `docs/IOS_APP_DIRECTION_LOCK.md`
- `docs/IOS_APP_PLAN.md`
- `docs/IOS_APP_ARCHITECTURE.md`
- `docs/IOS_APP_DESIGN_SYSTEM.md`
- `docs/IOS_APP_DEVELOPMENT_PHASES.md`
- `docs/IOS_APP_API_CONTRACT.md`
- `docs/IOS_APP_AI_PROMPTS.md`
- `docs/IOS_APP_CHECKLISTS.md`
```

## iOS App Phase 1 Status (web panel milestone)

- iOS companion app work is on branch `feature/ios-companion-app`.
- iOS source was created under `ios/PersonalCloudDownloader/`.
- XcodeGen setup was added with `project.yml`.
- Generated files are ignored:
  - `ios/PersonalCloudDownloader.xcodeproj/`
  - `ios/PersonalCloudDownloader/Info.plist`
- SwiftUI app shell exists with a TabView.
- Tabs exist for Home, Downloader, Videos, qBittorrent, Files, and Settings.
- Reusable WKWebView support was added using `WebView` and `WebScreen`.
- ATS HTTP loading support was added for private Tailscale URLs.
- Downloader tab loads `http://100.92.146.101:8090/app/`.
- qBittorrent tab loads `http://100.92.146.101:8080`.
- Files tab loads `http://100.92.146.101:8090/files/`.
- Home, Videos, and Settings are still placeholders.
- No backend, frontend web app, Oracle server, Nginx, qBittorrent, or Tailscale behavior was changed.
- Existing browser web downloader remains the main working app.

## iOS App Home and Settings Status (native milestone)

- Home tab is now a native SwiftUI dashboard.
- Home shows app title, private cloud downloader subtitle, Tailscale connection reminder, Oracle server IP, screen guide, and safety note.
- Settings tab is now a native SwiftUI Settings / Tailscale Helper screen.
- Settings shows server URLs, Tailscale-only privacy note, and an Open Tailscale helper button using `tailscale://`.
- Downloader, qBittorrent, and Files remain WKWebView tabs.
- Videos is still only a placeholder.
- No video player, API integration, torrent logic, backend change, frontend web app change, Oracle change, Nginx change, qBittorrent change, or Tailscale change was made.
- Existing browser web downloader remains unchanged and usable.

## Development Tooling: code-review-graph

- code-review-graph is being used as a code context/review helper for this project.
- Purpose: help AI coding tools understand the relevant files and affected code paths without reading the whole repo.
- It is a development workflow tool only.
- It is not part of the Personal Cloud Downloader app runtime.
- It should not change backend, frontend, iOS app behavior, Oracle, Nginx, qBittorrent, or Tailscale.
- It should be used when reviewing changes, finding affected files, or preparing safer coding prompts.

## iOS App Phase 2 Videos Library Status (native milestone)

- Phase 2 native Videos library was added.
- Videos tab fetches from `http://100.92.146.101:8000/api/completed-files`.
- A `CompletedFile` model matches the real backend JSON keys:
  - `name`
  - `path`
  - `url`
  - `modified_at`
- `backend/main.py` was read-only only to confirm JSON field names.
- `backend/main.py` was not modified.
- Videos filters video files client-side by extension: `mp4`, `mov`, `m4v`, `mkv`, `avi`, `webm`.
- Videos screen has loading, error with retry, empty state, list state, and pull-to-refresh.
- Video rows show title and modified date when available.
- Size is not shown because `/api/completed-files` currently does not return size.
- Tapping a video currently shows "Video player will be added later."
- No playback was added yet.
- No AVPlayer, MobileVLCKit, `/api/videos`, delete, download, copy link, torrent logic, backend change, frontend web app change, Oracle change, Nginx change, qBittorrent change, or Tailscale change was made.
- Videos remains a clean video library, not a file manager.
- code-review-graph is only development tooling, not app runtime.

## iOS App Phase 3 Player Core Status (player milestone)

- Phase 3 player core is complete.
- `PlayerView` was added as the dedicated video player route.
- `VideosView` now navigates to `PlayerView` using `NavigationLink` / `navigationDestination`.
- `CompletedFile` now supports `Hashable` and `streamURL` resolution.
- `backend/main.py` was read-only only to confirm `CompletedFile.url` is generated as a stream link; not modified.
- Deployed `CompletedFile.url` is an absolute, percent-encoded Nginx `/files/` URL: `http://100.92.146.101:8090/files/...`.
- AVPlayer / AVKit playback was added for `mp4`, `mov`, `m4v`.
- MobileVLCKit dependency setup was added with CocoaPods:
  - `ios/Podfile`
  - `pod 'MobileVLCKit', '~> 3.6.0'`
- CocoaPods generated files are ignored:
  - `ios/Pods/`
  - `ios/PersonalCloudDownloader.xcworkspace/`
- `Podfile.lock` should be committed after `pod install` creates it.
- `VLCPlayerView` was added for VLC playback.
- VLC engine is used for `mkv`, `avi`, `webm`.
- `VLCPlayerController` owns `VLCMediaPlayer` and manages playback state.
- VLC playback supports auto-play on open, stop on leave, play/pause, progress/time display, seek slider, and forward/back 10 second skip.
- AVPlayer branch remains intact.
- Videos remains a clean video library/player, not a file manager.
- No Delete, Download, or Copy Link controls were added to Videos.
- No backend endpoint changes were made.
- No `/api/videos` endpoint was created.
- No frontend web app, Oracle, Nginx, qBittorrent, or Tailscale behavior was changed.
- Existing web downloader remains unchanged and usable.
- Fullscreen, rotation, and error-state polish are not complete yet.

## iOS App Player Polish State-Handling Status (after Phase 3 player core)

- Player Polish state handling was added after the Phase 3 player core.
- VLC branch now has user-friendly playback states: loading/buffering, ready, failed, and ended.
- VLC branch UI:
  - buffering spinner while loading
  - playback-failed overlay with a Retry button
  - ended overlay with a Replay button
- VLC play/pause, seek slider, forward/back 10 second skip, auto-play on open, and stop-on-leave remain intact.
- AVPlayer branch now has basic state handling too: loading, ready, failed, and ended.
- AVPlayer branch keeps the system `VideoPlayer` controls.
- AVPlayer ended state shows Replay and auto-dismisses if playback resumes from the system controls.
- AVPlayer failed state shows Retry.
- VLC branch was not changed during the AVPlayer state work.
- Videos list was not changed.
- No backend, frontend web app, Oracle, Nginx, qBittorrent, Tailscale, or API endpoint behavior was changed.
- No Delete, Download, or Copy Link controls were added to Videos.
- Fullscreen and rotation are still not complete.

## iOS App Player Polish Fullscreen and Orientation Decision Status (after state-handling)

- Player Polish fullscreen mode was added.
- `PlayerView` now has fullscreen support using `fullScreenCover`.
- Fullscreen works for both the AVPlayer branch and the VLC branch.
- Inline and fullscreen player UI share extracted reusable player subviews.
- AVPlayer branch keeps `mp4`, `mov`, `m4v` behavior.
- VLC branch keeps `mkv`, `avi`, `webm` behavior.
- VLC play/pause, seek slider, forward/back 10 second skip, and loading/error/ended overlays remain intact.
- VLC drawable handling was improved so the player can reclaim the drawable when switching between inline and fullscreen.
- Orientation setup was inspected.
- `ios/project.yml` has no explicit orientation keys.
- The app already supports landscape by default.
- No forced rotation code was added.
- No app-wide orientation settings were changed.
- Decision: use zero-config orientation for now. The user can rotate the device manually in fullscreen.
- Forced auto-landscape rotation is intentionally deferred because it requires UIKit/app-wide orientation handling and has SwiftUI risk.
- No backend, frontend web app, Videos list, Oracle, Nginx, qBittorrent, Tailscale, or API behavior was changed.
- No Delete, Download, or Copy Link controls were added to Videos.

## iOS App Player Polish UI Status (after fullscreen and orientation decision)

- Player Polish UI step was completed.
- Only `PlayerView` layout/modifiers were changed.
- Player screen spacing was cleaned up with shared layout constants.
- Title area was improved with clearer hierarchy and tighter grouping.
- Inline player surface now has rounded corners and a subtle hairline border.
- Fullscreen player remains full-bleed and square.
- Fullscreen button placement and tap target were improved.
- VLC controls were visually reorganized:
  - slider/time group above
  - transport controls below
  - larger play/pause button
  - consistent skip button tap targets
- Time/progress spacing was aligned.
- AV and VLC overlay UI was deduplicated for consistent loading, failed, and ended states.
- Error and ended overlays were visually clarified.
- URL caption was made less distracting.
- AVPlayer logic was not changed.
- VLC logic was not changed.
- Fullscreen behavior was not changed.
- Zero-config orientation decision was not changed.
- Videos list was not changed.
- No backend, frontend web app, Oracle, Nginx, qBittorrent, Tailscale, or API behavior was changed.
- No Delete, Download, or Copy Link controls were added to Videos.
- Build was not verified yet because the current environment is Windows without Xcode.

## iOS App GitHub Actions Build Verification Status (after Player Polish UI)

- GitHub Actions iOS build check workflow was added: `.github/workflows/ios-build.yml`.
- The workflow runs on a macOS runner and performs `xcodegen generate`, `pod install`, and an `xcodebuild` compile check.
- The iOS app can now be build-checked without owning a Mac by using a GitHub Actions macOS runner.
- First CI failure was caused by `ContentUnavailableView` requiring iOS 17.
- `VideosView` empty state was changed to an iOS 16-compatible SwiftUI view.
- Deployment target remains iOS 16.0.
- Latest GitHub Actions run passed successfully.
- XcodeGen generation passed.
- CocoaPods install passed.
- MobileVLCKit 3.6.0 installed and linked successfully.
- `xcodebuild` compile check passed for iOS Simulator.
- This confirms compile/link success only.
- Real device testing, runtime playback testing, Tailscale runtime access, AVPlayer playback, VLC playback, fullscreen behavior, and actual iPhone testing are still pending.

## iOS App Device Runtime Testing Checklist Status (after GitHub Actions build verification)

- New doc was created: `docs/IOS_DEVICE_TEST_CHECKLIST.md`.
- Purpose: a real iPhone runtime verification checklist for the current iOS app status.
- It covers Tailscale pre-flight.
- It covers WKWebView tabs: Downloader, qBittorrent, Files.
- It covers native Videos fetch of `/api/completed-files`.
- It covers AVPlayer playback.
- It covers VLC playback.
- It covers fullscreen and manual landscape.
- It covers Settings / Open Tailscale.
- It includes pass/fail definitions.
- It includes failure evidence to collect.
- It includes must-not-change rules during testing.
- It includes a triage rule: if Safari cannot reach Oracle over Tailscale, fix network first before blaming the app.
- This is a test plan only; runtime / device testing is still NOT complete.
- CI compile success remains compile/link only.
- Real iPhone playback, Tailscale runtime access, AVPlayer playback, VLC playback, fullscreen behavior, and device testing remain pending.
- No code, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- No Delete, Download, or Copy Link controls were added to Videos.

## iOS App Personal iPhone Install Plan Status (after device runtime testing checklist)

- New doc was created: `docs/IOS_PERSONAL_INSTALL_PLAN.md`.
- Purpose: explains how the user can install and use the iOS app on their own iPhone without owning a Mac.
- Current constraint: the user does not own a Mac.
- Key fact: the GitHub Actions macOS runner can build the app, but signing and installation are still needed.
- The plan compares four paths:
  - Apple Developer Program + GitHub Actions signed IPA
  - TestFlight
  - Remote Mac
  - Free Apple ID + Sideloadly/AltStore
- Recommended path: try Free Apple ID + Sideloadly first for personal use; upgrade to the Apple Developer Program only if 7-day re-signing becomes annoying.
- Runtime/device testing is still required using `docs/IOS_DEVICE_TEST_CHECKLIST.md`.
- No signing workflow has been created yet.
- No `project.yml` bundle ID change has been made yet.
- Real iPhone runtime testing is still NOT complete.
- No code, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- No new iOS feature was added.

## iOS App Unsigned Device IPA Plan Status (after personal iPhone install plan)

- New doc was created: `docs/IOS_UNSIGNED_DEVICE_IPA_PLAN.md`.
- Purpose: a plan for creating an unsigned real-device iPhone IPA artifact using GitHub Actions for Sideloadly/AltStore.
- Key idea:
  - the current simulator build cannot install on iPhone
  - a separate device build is needed using a generic iOS device destination
  - signing stays disabled in CI
  - manually package `Payload/*.app` into an unsigned `.ipa`
- The existing `iOS Build Check` workflow remains unchanged and should stay as the compile/link gate.
- The future workflow should be separate and `workflow_dispatch`-only.
- MobileVLCKit arm64 device-link is still unverified and is the main unknown.
- Recommended order:
  1. Add a separate unsigned device IPA workflow later.
  2. Run it manually.
  3. Confirm device arm64 / MobileVLCKit link.
  4. Download the artifact.
  5. Install with Sideloadly/AltStore.
  6. Run `docs/IOS_DEVICE_TEST_CHECKLIST.md`.
- No unsigned IPA workflow has been created yet.
- No `project.yml` bundle ID change has been made yet.
- Real iPhone install/runtime testing is still NOT complete.
- No code, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- No new iOS feature was added.

## iOS App Unsigned Device IPA Workflow Status (after unsigned device IPA plan)

- New workflow was created: `.github/workflows/ios-unsigned-ipa.yml`.
- Purpose: a manual GitHub Actions workflow to build a real-device unsigned iPhone IPA artifact for Sideloadly/AltStore.
- Workflow trigger is `workflow_dispatch` only.
- The existing `iOS Build Check` workflow remains unchanged.
- Workflow uses:
  - macos-15
  - `xcodegen generate`
  - `pod install`
  - `xcodebuild archive` for generic iOS device
  - Release configuration
  - signing disabled
  - manual `Payload/*.app` to `.ipa` packaging
  - artifact upload
- It does NOT use `xcodebuild -exportArchive`.
- It does NOT sign the app.
- It does NOT install the app on iPhone.
- It does NOT verify runtime playback or device behavior.
- MobileVLCKit arm64 device-link is still unverified until the workflow is manually run.
- Real iPhone install/runtime testing is still NOT complete.
- No iOS Swift code, `project.yml`, `Podfile`, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- No new iOS feature was added.

## iOS App Unsigned Device IPA Workflow Verification Status (after unsigned device IPA workflow creation)

- The manual GitHub Actions workflow `.github/workflows/ios-unsigned-ipa.yml` passed.
- The workflow successfully built a real-device iPhone archive.
- The workflow successfully created an unsigned IPA artifact.
- MobileVLCKit arm64 device link is now verified by CI.
- This confirms device build/link success only.
- The IPA is still unsigned.
- The app is not installed on iPhone yet.
- Sideloadly/AltStore install is still pending.
- Real iPhone runtime testing is still NOT complete.
- AVPlayer runtime playback, VLC runtime playback, fullscreen behavior, Tailscale runtime access, and the real device checklist are still pending.
- No code, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- No new iOS feature was added.

## iOS App Personal iPhone Install Success Status (after unsigned device IPA workflow verification)

- The unsigned IPA artifact was downloaded from GitHub Actions.
- The app was installed on the user's iPhone using Sideloadly on Windows.
- The Apple Devices app was needed so Windows/Sideloadly could detect the iPhone.
- Developer Mode was required and enabled on the iPhone.
- The app now opens on the iPhone.
- This confirms personal iPhone install success.
- This does NOT confirm runtime app behavior yet.
- Tailscale runtime access, WKWebView tabs, Videos fetch, AVPlayer playback, VLC playback, fullscreen behavior, landscape behavior, and the full device checklist are still pending.
- Runtime testing must continue using `docs/IOS_DEVICE_TEST_CHECKLIST.md`.
- No code, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- No new iOS feature was added.

## iOS App VLC Fullscreen/Player Runtime-Verified Status (after personal iPhone install success)

- Real iPhone runtime testing verified these VLC player fixes.
- Inline VLC playback works.
- VLC resume position works (same video resumes during the session).
- VLC fullscreen video now renders correctly.
- The separate fullscreen VLC player approach fixed the blank fullscreen / drawable issue.
- Closing fullscreen returns to inline playback correctly.
- VLC fullscreen controls auto-hide works.
- VLC fullscreen close button accessibility was improved and verified.
- VLC fake-landscape fullscreen works, including with device rotation lock ON.
- VLC aspect/ratio selector exists (Fit, Zoom/Aspect Fill, 16:9, 4:3, 1:1, Stretch).
- Zoom / Aspect Fill was improved and is acceptable for now.
- Remaining issues (NOT done):
  - Subtitles still not working.
  - qBittorrent WebView error still remains.
  - The full device runtime checklist (`docs/IOS_DEVICE_TEST_CHECKLIST.md`) is not completely finished yet.
- No backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.

## iOS App VLC Subtitle Overlay + Backend Extraction Status (after VLC fullscreen/player runtime-verified)

- VLC subtitles now work via an app-rendered sidecar `.srt` SwiftUI overlay, runtime-verified on a real iPhone.
- The overlay is drawn by the app (screen-space), NOT native VLC SPU, so it stays bottom-centered and stable in Cover / Aspect Fill (native VLC subtitles shift with the crop).
- The fullscreen ratio control is now a Fit ⇄ Cover toggle; the earlier 16:9 / 4:3 / 1:1 / Stretch / crop-Zoom modes were removed.
- Backend change WAS made this milestone: new endpoint `POST /api/subtitles/extract`.
  - It validates the path under the completed-downloads dir and rejects traversal.
  - It uses `ffprobe` to detect subtitle streams and `ffmpeg` to convert the first text track (English-preferred) into `<video>.srt` beside the video.
  - It returns statuses: `extracted`, `exists`, `no_text_subtitles`, `image_subtitles_only`, `ffmpeg_unavailable`, `extraction_failed`.
  - It does not overwrite an existing `.srt`, and it does not run in the background or hook download completion.
- `ffmpeg`/`ffprobe` extraction works on the Oracle server (`ffmpeg` was added to the server install checklist in `scripts/install-server.sh`).
- iOS flow verified end-to-end: `.srt` 404 → `POST /api/subtitles/extract` → backend creates `.srt` → iOS retries `.srt` once → SwiftUI overlay activates.
- Native VLC embedded subtitle fallback still exists when extraction is unavailable.
- Image-based subtitles (PGS/VobSub/DVD/DVB) remain unsupported for extraction without OCR; those videos keep the native fallback.
- New files: `ios/PersonalCloudDownloader/Services/SRTSubtitleParser.swift`. Changed: `VLCPlayerView.swift`, `PlayerView.swift`, `backend/main.py`, `scripts/install-server.sh`.
- Remaining issues (NOT done):
  - qBittorrent WebView error still remains.
  - The full device runtime checklist (`docs/IOS_DEVICE_TEST_CHECKLIST.md`) is not confirmed complete unless verified separately.
- No frontend web app, qBittorrent, or Tailscale behavior was changed.
