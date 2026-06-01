# Progress

## 2026-06-02

- iOS Player Polish UI milestone (branch `feature/ios-companion-app`); added after the fullscreen and orientation decision.
- Player Polish UI step was completed.
- Only `PlayerView` layout/modifiers were changed.
- Player screen spacing cleaned up with shared layout constants.
- Title area improved with clearer hierarchy and tighter grouping.
- Inline player surface now has rounded corners and a subtle hairline border.
- Fullscreen player remains full-bleed and square.
- Fullscreen button placement and tap target improved.
- VLC controls visually reorganized: slider/time group above, transport controls below, larger play/pause button, consistent skip button tap targets.
- Time/progress spacing aligned.
- AV and VLC overlay UI deduplicated for consistent loading, failed, and ended states.
- Error and ended overlays visually clarified.
- URL caption made less distracting.
- AVPlayer logic not changed; VLC logic not changed; fullscreen behavior not changed.
- Zero-config orientation decision not changed.
- Videos list not changed.
- No backend, frontend web app, Oracle, Nginx, qBittorrent, Tailscale, or API behavior changed.
- No Delete, Download, or Copy Link controls added to Videos.
- Build not verified yet because the current environment is Windows without Xcode.

## 2026-06-01

- iOS Player Polish fullscreen and orientation decision milestone (branch `feature/ios-companion-app`); added after state-handling.
- Player Polish fullscreen mode was added.
- `PlayerView` now has fullscreen support using `fullScreenCover`.
- Fullscreen works for both the AVPlayer branch and the VLC branch.
- Inline and fullscreen player UI share extracted reusable player subviews.
- AVPlayer branch keeps `mp4`, `mov`, `m4v` behavior.
- VLC branch keeps `mkv`, `avi`, `webm` behavior.
- VLC play/pause, seek slider, ±10s skip, and loading/error/ended overlays remain intact.
- VLC drawable handling improved so the player can reclaim the drawable when switching between inline and fullscreen.
- Orientation setup was inspected; `ios/project.yml` has no explicit orientation keys.
- The app already supports landscape by default.
- No forced rotation code added; no app-wide orientation settings changed.
- Decision: use zero-config orientation for now. User can rotate the device manually in fullscreen.
- Forced auto-landscape rotation intentionally deferred because it requires UIKit/app-wide orientation handling and has SwiftUI risk.
- No backend, frontend web app, Videos list, Oracle, Nginx, qBittorrent, Tailscale, or API behavior changed.
- No Delete, Download, or Copy Link controls added to Videos.

## 2026-06-01

- iOS Player Polish state-handling milestone (branch `feature/ios-companion-app`); added after Phase 3 player core.
- VLC branch now has user-friendly playback states: loading/buffering, ready, failed, ended.
- VLC branch UI: buffering spinner, playback-failed overlay with Retry, ended overlay with Replay.
- VLC play/pause, seek slider, ±10s skip, auto-play on open, and stop-on-leave remain intact.
- AVPlayer branch now has basic state handling too: loading, ready, failed, ended.
- AVPlayer branch keeps the system `VideoPlayer` controls.
- AVPlayer ended state shows Replay and auto-dismisses if playback resumes from the system controls.
- AVPlayer failed state shows Retry.
- VLC branch was not changed during the AVPlayer state work.
- Videos list was not changed.
- No backend, frontend web app, Oracle, Nginx, qBittorrent, Tailscale, or API endpoint behavior changed.
- No Delete, Download, or Copy Link controls added to Videos.
- Fullscreen and rotation are still not complete.

## 2026-06-01

- iOS Phase 3 player core milestone complete (branch `feature/ios-companion-app`).
- `PlayerView` added as the dedicated video player route.
- `VideosView` now navigates to `PlayerView` via `NavigationLink` / `navigationDestination`.
- `CompletedFile` now supports `Hashable` and `streamURL` resolution.
- `backend/main.py` was read-only only to confirm `CompletedFile.url` is generated as a stream link; not modified.
- Deployed `CompletedFile.url` is an absolute, percent-encoded Nginx `/files/` URL: `http://100.92.146.101:8090/files/...`.
- AVPlayer / AVKit playback added for `mp4`, `mov`, `m4v`.
- MobileVLCKit dependency setup added with CocoaPods: `ios/Podfile`, `pod 'MobileVLCKit', '~> 3.6.0'`.
- CocoaPods generated files ignored: `ios/Pods/` and `ios/PersonalCloudDownloader.xcworkspace/`.
- `Podfile.lock` should be committed after `pod install` creates it.
- `VLCPlayerView` added for VLC playback; VLC engine used for `mkv`, `avi`, `webm`.
- `VLCPlayerController` owns `VLCMediaPlayer` and manages playback state.
- VLC playback supports auto-play on open, stop on leave, play/pause, progress/time display, seek slider, and forward/back 10 second skip.
- AVPlayer branch remains intact.
- Videos remains a clean video library/player, not a file manager.
- No Delete, Download, or Copy Link controls added to Videos.
- No backend endpoint changes; no `/api/videos` endpoint created.
- No frontend web app, Oracle, Nginx, qBittorrent, or Tailscale behavior changed.
- Existing web downloader remains unchanged and usable.
- Fullscreen, rotation, and error-state polish not complete yet.

## 2026-06-01

- iOS Phase 2 native Videos library milestone (branch `feature/ios-companion-app`).
- Videos tab fetches from `http://100.92.146.101:8000/api/completed-files`.
- `CompletedFile` model matches real backend keys: `name`, `path`, `url`, `modified_at`.
- `backend/main.py` was read-only only to confirm JSON field names; not modified.
- Videos filters video files client-side by extension: `mp4`, `mov`, `m4v`, `mkv`, `avi`, `webm`.
- Videos screen has loading, error with retry, empty state, list state, and pull-to-refresh.
- Video rows show title and modified date when available.
- Size not shown because `/api/completed-files` currently does not return size.
- Tapping a video currently shows "Video player will be added later."
- No playback added yet.
- No AVPlayer, MobileVLCKit, `/api/videos`, delete, download, copy link, torrent logic, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- Videos remains a clean video library, not a file manager.

## 2026-06-01

- Adopted code-review-graph as a code context/review helper for this project.
- Purpose: help AI coding tools understand relevant files and affected code paths without reading the whole repo.
- Development workflow tool only; not part of the Personal Cloud Downloader app runtime.
- Must not change backend, frontend, iOS app behavior, Oracle, Nginx, qBittorrent, or Tailscale.
- Use it when reviewing changes, finding affected files, or preparing safer coding prompts.

## 2026-06-01

- iOS Home and Settings native milestone (branch `feature/ios-companion-app`).
- Home tab is now a native SwiftUI dashboard: app title, private cloud downloader subtitle, Tailscale connection reminder, Oracle server IP, screen guide, safety note.
- Settings tab is now a native SwiftUI Settings / Tailscale Helper screen: server URLs, Tailscale-only privacy note, Open Tailscale button via `tailscale://`.
- Downloader, qBittorrent, and Files remain WKWebView tabs.
- Videos is still only a placeholder.
- No video player, API integration, torrent logic, backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale change was made.
- Existing browser web downloader remains unchanged and usable.

## 2026-06-01

- iOS companion app Phase 1 web panel milestone (branch `feature/ios-companion-app`).
- iOS source created under `ios/PersonalCloudDownloader/`.
- XcodeGen setup added with `project.yml`.
- Generated files ignored: `ios/PersonalCloudDownloader.xcodeproj/` and `ios/PersonalCloudDownloader/Info.plist`.
- SwiftUI app shell with TabView: Home, Downloader, Videos, qBittorrent, Files, Settings.
- Reusable WKWebView support added (`WebView`, `WebScreen`).
- ATS HTTP loading support added for private Tailscale URLs.
- Downloader tab loads `http://100.92.146.101:8090/app/`.
- qBittorrent tab loads `http://100.92.146.101:8080`.
- Files tab loads `http://100.92.146.101:8090/files/`.
- Home, Videos, and Settings remain placeholders.
- No backend, frontend web app, Oracle, Nginx, qBittorrent, or Tailscale behavior changed.
- Existing browser web downloader remains the main working app.

## 2026-05-29

- Added AWS EC2 Free Tier setup path for Tokyo region.
- Marked AWS as the practical small-storage path while keeping the Oracle plan.

## 2026-05-29

- Moved project plan into `docs/PERSONAL_CLOUD_DOWNLOADER_PLAN.md`.
- Bootstrapped private personal cloud downloader MVP skeleton.
- Added FastAPI backend starter files.
- Added plain HTML/CSS/JS frontend starter files.
- Added setup, security, and usage docs.
- Added safe server helper scripts.
