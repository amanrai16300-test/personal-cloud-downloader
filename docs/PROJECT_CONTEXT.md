# Personal Cloud Downloader Project Context

## 1. Project Overview

- Project name: Personal Cloud Downloader / CloudBox.
- Goal: private personal cloud downloader and media streamer for legal files only.
- Main use: download legal files on a cloud server, then stream or download privately from browser, VLC, iPhone, or Windows.
- Download size rule: keep downloads under 10GB.
- Retention rule: delete downloaded files quickly after use.
- Privacy rule: qBittorrent, file streaming, FastAPI, web app, and future backend services stay private through Tailscale.
- Active production provider: Oracle Cloud Always Free A1.
- AWS exists only as stopped historical backup.

## 2. Current Production Environment

This section is authoritative. Use these values for current work.

- Active environment: Oracle Cloud Always Free A1.
- Server hostname: `personal-cloud-downloader-vcn`.
- Current Tailscale IP: `100.95.39.107`.
- Current private Oracle IP: `10.0.0.129`.
- Public IP: not recently verified; do not assume a current public IP.
- Access path: Tailscale only.
- OS: Ubuntu 24.04.
- VM: about 4GB RAM, about 50GB boot/root disk, about 100GB CloudBox storage volume.

SSH:

```powershell
ssh -i "$env:USERPROFILE\.ssh\oracle-personal-cloud-downloader-key" ubuntu@100.95.39.107
```

Current private services:

```text
FastAPI:      http://100.95.39.107:8000
qBittorrent:  http://100.95.39.107:8080
Web/files:    http://100.95.39.107:8090
Web app:      http://100.95.39.107:8090/app/
Files:        http://100.95.39.107:8090/files/
```

Historical IP warning:

- Historical Oracle Tailscale IP `100.92.146.101` is no longer current.
- Historical AWS Tailscale IP `100.125.15.118` is backup-only history.
- Do not use historical IP addresses for SSH, deployment, API calls, WebViews, or testing.
- Use only current Oracle Tailscale IP `100.95.39.107`.

## 3. Security / Usage Rules

- Use only for legal files.
- Keep downloads under 10GB.
- Delete completed files quickly after streaming or downloading.
- Pause or remove torrents after completion.
- Avoid seeding unless intentionally needed.
- Keep qBittorrent, Nginx file streaming, FastAPI, web app, and future services private through Tailscale.
- Do not expose ports `8080`, `8090`, or `8000` publicly.
- UFW should allow `22`, `8080`, `8090`, and `8000` only on `tailscale0`.
- Do not store private keys, API keys, passwords, PEM contents, tokens, or secret values in this repo.
- Oracle budget alert exists for cost warning only; alerts do not stop resources.
- AWS EC2 is stopped and should not be used unless needed as backup.

## Mythos-Level Prompt Standard + Code Review Graph Workflow

- For this project, "Mythos-level" does not mean long.
- It means prompts must be short, exact, evidence-first, root-cause-focused, and designed to solve the exact CloudBox problem with the smallest safe edit.
- Every coding/debugging prompt must start with: `Start with the most related file to this task. Stop and ask before reading any other file.`
- For non-trivial debugging, trace the exact broken path before coding: file -> UI/view/template -> handler/view model -> state/data/API request -> backend/helper -> condition causing the bug.
- Require the exact root cause before code changes.
- Use the Code Review Graph MCP first when the affected file is unknown or the bug may cross multiple files.
- Prefer graph-guided file discovery over rereading the whole repository.
- If the target file is already known, start there first and use the graph only if that file does not explain the bug.
- For very small known-file changes, skip graph exploration and keep the prompt ultra-short.
- Minimal useful evidence:
  - backend/API: request URL, payload, status code, response body, exact backend error.
  - iOS: affected screen, exact tap/path, visible error, relevant console/build error if available.
  - web UI: affected URL, exact button/action, console error, network request/response if needed.
- For tricky bugs only, include a short internal council: Bug Hunter, UX Reviewer, State/API Reviewer, Minimal Fix Reviewer.
- For simple text/UI/CSS/SwiftUI changes, skip the council and keep the prompt ultra-short.

## 4. Current Deployment Paths and Rules

Verified current paths:

```text
Local backend:        backend/main.py
Live Oracle backend:  /home/ubuntu/personal-cloud-downloader/backend/main.py

Local web frontend:        frontend/app.js
Live Oracle web frontend:  /home/ubuntu/personal-cloud-downloader/backend/app.js

Local Trends script:  scripts/fetch_trends.py
Live Trends script:   /home/ubuntu/personal-cloud-downloader/scripts/fetch_trends.py

Generated Trends data:  /tmp/trends.json
TMDB env file:          /home/ubuntu/.config/cloudbox/tmdb.env
```

Deployment rules:

- Backend changes: copy `backend/main.py` to live backend path, run `python3 -m py_compile backend/main.py`, then restart `personal-downloader-api.service`.
- Web changes: copy `frontend/app.js` to live `backend/app.js`; normally no backend restart.
- Trends script-only changes: copy `scripts/fetch_trends.py`, run `python3 -m py_compile scripts/fetch_trends.py`, then run with TMDB env.
- Native iOS changes: build new unsigned IPA through manual GitHub Actions workflow, then install through Sideloadly.
- Documentation-only changes: no Oracle deploy and no IPA build.
- Oracle project folder `/home/ubuntu/personal-cloud-downloader` is not a Git repo; use clone-copy/manual deploy discipline.

Backend restart command:

```bash
sudo systemctl restart personal-downloader-api.service
```

## 5. Current Backend / API Status

Backend framework: FastAPI.

Core endpoints:

- `GET /api/health`
- `GET /api/qbittorrent/test`
- `POST /api/add-magnet`
- `GET /api/torrents`
- `DELETE /api/torrents/{hash}`
- `GET /api/completed-files`
- `POST /api/video-progress`
- `GET /api/video-progress`
- `POST /api/subtitles/extract`
- `GET /api/network-usage`
- `GET /api/trends`
- `GET /api/home-dashboard`
- `POST /api/convert-markdown`
- `POST /api/convert-markdown-url`

Torrent behavior:

- New torrents download successfully through qBittorrent.
- Backend monitor auto-pauses completed, uploading, and seeding torrents when enabled.
- `/api/torrents` returns simple Seedr-style fields: `hash`, `name`, `status`, `progress_percent`, `size`, `download_speed`, `eta`, `is_complete`.
- Completed `eta` is normalized to `0`.
- Delete endpoint removes qBittorrent entry and downloaded files.
- Files are not auto-deleted after completion; deletion happens only when user calls delete.

Completed files and media:

- Completed downloads root: `/srv/personal-cloud/downloads/complete`.
- `/api/completed-files` returns files actually on disk.
- It filters support/extra files such as screenshots, images, `.nfo`, `.txt`, and samples.
- Loose root videos auto-move into same-stem folders during `/api/completed-files`.
- Matching same-stem `.srt` and `.vtt` sidecars move with video.
- `_cloudbox-thumbnails` is excluded from normal file/folder results.
- Optional `thumbnail_url` is returned for videos.

Thumbnails:

- Backend generates one `.jpg` thumbnail per video using `ffmpeg`.
- Thumbnail cache path: `/srv/personal-cloud/downloads/complete/_cloudbox-thumbnails/`.
- Existing good thumbnails are reused.
- Bad/tiny thumbnails under 2KB are deleted and regenerated.
- Generation tries timestamps `10s`, `30s`, `60s`, then `1s`.
- Thumbnail failure for one video does not crash `/api/completed-files`.

Subtitles:

- `POST /api/subtitles/extract` validates path under completed-downloads root.
- Uses `ffprobe` to detect subtitle streams and `ffmpeg` to convert first text track, English-preferred, into `<video>.srt`.
- Return statuses include `extracted`, `exists`, `no_text_subtitles`, `image_subtitles_only`, `ffmpeg_unavailable`, `extraction_failed`.
- Does not overwrite existing `.srt`.
- Does not run in background or hook download completion.
- Image-based subtitles are unsupported for extraction without OCR; native VLC fallback may still apply.
- Backend sanitizes active `.srt` and `.vtt` sidecars, removing common HTML tags/entities and ASS/SSA override tags while preserving timing.
- Existing subtitle files get one `.bak` backup before sanitization.

CloudBox subtitle search and selection checkpoint:

- Changed files: `backend/main.py`, `ios/PersonalCloudDownloader/Views/PlayerView.swift`, `ios/PersonalCloudDownloader/Views/VLCPlayerView.swift`.
- Backend subtitle search added `POST /api/subtitles/search`; existing `POST /api/subtitles/extract` remains.
- OpenSubtitles.com REST API uses env-only config: `OPENSUBTITLES_API_KEY`, `OPENSUBTITLES_USERNAME`, `OPENSUBTITLES_PASSWORD`.
- Missing OpenSubtitles env returns `provider_not_configured` before provider calls or file creation.
- Existing full/usable `.srt` returns `exists`; existing partial/forced or invalid `.srt` no longer blocks provider search.
- Match threshold is `72.0`; episode subtitles require exact season+episode match.
- Low-confidence matches return `low_confidence` and do not replace the subtitle; no candidates return `not_found`.
- Saved subtitles use `<video>.srt`, temp write/atomic replace, backup for replaced partial subtitle, and existing sanitizer.
- Existing `.srt` is never blindly overwritten.
- Oracle checks verified: `/api/health` returns ok; `/api/home-dashboard` returns 200 JSON after helper-conflict fix; `provider_not_configured` verified before real env values; OpenSubtitles env attached through systemd drop-in; `not_found` verified for a no-sidecar file; Thunderbolts partial sidecar search returned `low_confidence` with score around `60.48`, so backend safely kept existing subtitle.
- Home dashboard fix: duplicate helper conflict in `backend/main.py` was fixed by renaming the Home parser helper to `clean_home_media_title`; root cause was subtitle helper `clean_media_title(text)` conflicting with the Home helper that expected three args.
- iOS VLC subtitle menu now combines all subtitle sources instead of choosing sidecar OR embedded.
- Sidecar-only menu: `Subtitles`, `Off`, `Find better subtitles`.
- Embedded-only menu: each VLC embedded subtitle track, `Off`, `Find subtitles`.
- Sidecar + embedded menu: `Subtitles`, every VLC embedded track, `Off`, `Find better subtitles`.
- No subtitles menu: `Off`, `Find subtitles`.
- Selecting sidecar uses the existing sidecar overlay path; selecting embedded tracks uses real VLC track names/indexes.
- `Find subtitles` and `Find better subtitles` both call existing `/api/subtitles/search`.
- Thunderbolts was verified conceptually: sidecar plus embedded tracks should be selectable; embedded English can be selected instead of the partial sidecar.
- Checks passed: `python3 -m py_compile backend/main.py`; `git diff --check`.
- Swift compile unavailable locally.

Network/storage:

- `GET /api/network-usage` uses fixed safe server commands only.
- Commands include `vnstat -i enp0s6 --json`, fallback `vnstat -i enp0s6`, `df -B1 /`, and optional `df -B1 /srv/personal-cloud/downloads/complete`.
- No client command input is accepted.

## 6. Current iOS App Status

- App name: CloudBox.
- Source: `ios/PersonalCloudDownloader/`.
- UI stack: SwiftUI, WKWebView, URLSession/Codable, AVPlayer/AVKit, MobileVLCKit.
- Display name fixed through XcodeGen.
- App icon asset exists under `ios/PersonalCloudDownloader/Assets.xcassets/AppIcon.appiconset/`.
- Bottom tabs: Home, Downloader, Videos, Network, More.
- qBittorrent, Files, Settings, Trends are reached from More.
- ATS HTTP loading supports private Tailscale URLs.
- Tailscale remains a separate app; CloudBox has helper/open action only.
- iPhone never runs torrent downloading locally.

Current app capabilities:

- Home dashboard with aggregated backend data, Continue Watching, Recently Added, TMDB artwork, movie playback, and series folder navigation.
- Downloader tab loads web UI at `/app/`.
- Videos tab is native media library/player.
- Network tab shows live network/storage usage.
- Trends screen shows legal TMDB metadata only.
- Markdown Converter supports file picker, Photos picker, paste URL, preview, Copy, Share, Save `.md`, Retry, and Clear.
- qBittorrent and Files use WKWebView.
- Settings includes Tailscale helper and endpoint/privacy info.

Install/build:

- Manual GitHub Actions workflow builds unsigned device IPA.
- Personal install method: download unsigned IPA and install with Sideloadly on Windows.
- Apple Devices app may be needed for Windows/Sideloadly device detection.
- Developer Mode must be enabled on iPhone.
- Native iOS changes require a new IPA build/install.

qBittorrent WebView:

- Shared `WKWebView` uses persistent `WKWebsiteDataStore.default()`.
- `NSURLErrorDomain -999` cancelled navigation is not shown as failed-load screen.
- Popup/`target=_blank` handling stays inside app WebView.
- Redirect reload loop was reduced.
- Remaining limitation: after fully closing/reopening app, qB login page may return because qB session/cookie may be session-only.
- No qB username/password is hardcoded in app.

## 7. Current Web Downloader Status

- Local web frontend: `frontend/app.js`.
- Live Oracle frontend: `/home/ubuntu/personal-cloud-downloader/backend/app.js`.
- Web app URL: `http://100.95.39.107:8090/app/`.
- Web UI can add legal magnet links, show progress, show completed files, stream/download files, copy VLC links, delete torrents/files, and show Trends.
- Completed Files uses `GET /api/completed-files`.
- Completed Files auto-updates after completion with short polling delay.
- Copy VLC link works over HTTP/Tailscale with clipboard fallback.
- Custom delete confirmation modal is in-page DOM, not `window.confirm()`, so it works in browser and iOS WKWebView.
- Queue ordering shows active/current downloads above completed/old downloads.
- `frontend/app.js` injects `installCloudBoxTheme()`.
- Theme is self-contained in `app.js`; `index.html` and `style.css` remain unchanged.
- The themed `app.js` is deployed to Oracle.

## 8. Current Home Dashboard + TMDB Artwork

Backend endpoint: `GET /api/home-dashboard`.

Aggregated response includes:

- `server`: online, Oracle/Tokyo location, real uptime, last-updated timestamp, API/qBittorrent/storage service status.
- `library`: playable-video count, indexed/completed-file count, storage used bytes, storage total bytes.
- `downloads`: real active torrent count.
- `network`: current RX bytes/second, current TX bytes/second.
- `continue_watching`.
- `recently_added`.

Implementation:

- Reuses existing video, progress, thumbnail, qBittorrent, storage, and network helpers.
- `video_id` equals safe relative path used by existing player flow.
- Absolute filesystem paths are never exposed.
- Continue Watching selects most recently watched unfinished video.
- Continue Watching excludes missing videos and videos at or above 90% watched.
- Continue Watching returns saved position, duration, and normalized progress from `0.0` to `1.0`.
- Filename parsing removes release noise, detects year, detects `S01E05` and `1x05`, uses parent-folder metadata as fallback, and removes dangling punctuation.
- Recently Added returns up to 40 newest raw playable videos.
- iOS groups episodes into unique series/movie entries and displays up to 8 unique entries.
- Movies open existing player directly.
- Series open existing Videos folder/detail episode picker.
- VLC resume position is seeded through existing progress store before opening.
- Existing AVPlayer/VLC routing is preserved.

Home behavior:

- Current Home uses one aggregated `GET /api/home-dashboard`.
- Latency is measured client-side in iOS using request round-trip time.
- Foreground reconnect works without tab switch.

Latest iOS Home reconnect/performance checkpoint:

- Changed file: `ios/PersonalCloudDownloader/Views/HomeView.swift`.
- Root cause: Home first paint waited on a serial foreground chain: `/api/health` probe gate -> `GET /api/home-dashboard` -> full `GET /api/completed-files` library fetch/grouping -> one final state update. Cold launch had no persisted Home snapshot, so Home stayed in CHECKING/loading until the full chain completed.
- Fix: Home uses a two-phase refresh. Phase 1 applies `/api/home-dashboard` immediately and keeps existing Recently Added entries visible; Phase 2 runs `CompletedFilesAPI.fetchVideos()` and applies only regrouped Recently Added entries afterward.
- Stale safety: both phases use the existing generation guard, so old dashboard or library responses cannot overwrite newer Home state.
- Cache-first launch: Home persists a small last-good dashboard snapshot in `UserDefaults` and renders it on first appear/cold launch. Cached data does not fake live latency; connection status and latency still refresh live.
- Foreground reconnect: Home restarts refresh immediately on `reconnectCycle`/foreground while visible, treating `/api/home-dashboard` as the Home health check instead of waiting for the separate `/api/health` probe. `reconnectRefreshToken` remains supported.
- Duplicate refresh prevention: Home skips refresh starts when a loop already started within about 3 seconds, preventing `onAppear`, foreground, and reconnect token from launching duplicate chains.
- Unchanged: `RootTabView.swift`, `CompletedFilesAPI.swift`, `backend/main.py`, API response shape, Home visual design, tabs, player/progress behavior, Web Downloader, Tailscale/private/legal rules.

TMDB artwork:

- Backend enriches Home dashboard media with TMDB server-side using `TMDB_API_KEY`.
- Movie search uses `/search/movie`; series search uses `/search/tv`.
- Search uses normalized title, media type, and year when available.
- Exact normalized-title match is required.
- Conflicting years are rejected.
- Missing key, network failure, non-200 response, parse failure, or no match returns `null` safely.
- Successful and no-match results use in-process TTL cache.
- TMDB failures do not fail `/api/home-dashboard`.
- API key is never returned to iOS.
- Images are not permanently downloaded.
- Returned artwork fields: `tmdb_id`, `poster_url`, `backdrop_url`.
- iOS priority for Continue Watching: backdrop, poster, local thumbnail, placeholder.
- iOS priority for Recently Added: poster, local thumbnail, placeholder.

TMDB env:

```text
/home/ubuntu/.config/cloudbox/tmdb.env
```

Current env format for systemd compatibility:

```text
TMDB_API_KEY=...
```

FastAPI systemd drop-in:

```text
/etc/systemd/system/personal-downloader-api.service.d/tmdb.conf
```

Drop-in uses:

```text
EnvironmentFile=/home/ubuntu/.config/cloudbox/tmdb.env
```

Important follow-up:

- TMDB Trends cron must be retested after `tmdb.env` format changed from `export TMDB_API_KEY=...` to `TMDB_API_KEY=...`.
- Do not claim Trends cron remains verified after this env-format change unless retested.

## 9. Current Markdown Converter

Backend:

- `POST /api/convert-markdown`
- Supports existing document formats plus images: `.jpg`, `.jpeg`, `.png`, `.webp`.
- Image OCR uses local Tesseract with English and Japanese language data.
- Image preprocessing includes orientation correction, grayscale/contrast/sharpness improvements, and safe OCR cleanup.
- File upload limit is 25MB.
- OCR/Markdown formatting creates headings, sections, bullets, numbered lists, and cleaner paragraphs where safely detectable.
- Bad/blank conversions return empty result safely.

URL conversion:

- `POST /api/convert-markdown-url`
- Accepts public `http://` and `https://` URLs.
- Blocks empty URLs, invalid schemes, localhost, loopback, private/internal IPs, and link-local/internal hosts.
- Enforces download timeout and 5MB HTML limit.
- Downloaded HTML and converted Markdown are not persisted.
- Limitations: no login-only pages, no JavaScript browser rendering, no browser automation, no AI cleanup; converted pages may contain navigation/footer noise.

iOS:

- File picker, Photos picker, paste URL.
- Rendered Markdown preview.
- Copy, Share, Save `.md`, Retry, Clear.
- Empty-result and friendly error states.
- Keyboard does not auto-open.
- Done, Convert, outside tap, and scroll can dismiss keyboard.
- UI is CloudBox document-workbench style; preview is dark/readable.
- Action bar clearance above custom floating tab bar was fixed.

## 10. Current Player / Real Landscape / Timeline Status

Playback:

- AVPlayer/AVKit handles `mp4`, `mov`, `m4v`.
- MobileVLCKit handles `mkv`, `avi`, `webm`.
- Videos remain clean library/player, not file manager.
- No Delete, Download, or Copy Link controls in native Videos.
- VLC supports auto-play, stop-on-leave, play/pause, progress/time display, seeking, 10-second skip, loading/failed/ended overlays, replay, resume, subtitles, audio selector, gestures, and Fit/Cover.
- Multi-audio track selection uses MobileVLCKit real track indexes/names.
- Audio icon appears only when more than one selectable audio track exists.
- Subtitle overlay uses app-rendered sidecar `.srt` SwiftUI overlay, stable in Cover/Aspect Fill.
- Native VLC embedded subtitle fallback still exists when extraction is unavailable.

Latest iOS VLC player preference memory checkpoint:

- Changed files: `ios/PersonalCloudDownloader/Views/PlayerView.swift`, `ios/PersonalCloudDownloader/Views/VLCPlayerView.swift`.
- Commit confirmed/pushed: `99e190a Fix Home reconnect and VLC player preferences`; verified on iPhone after building/installing the new IPA.
- Earlier failed tests used an installed app without the preference code because the first attempt had a compile blocker: `PlayerPreference: Codable` stored `AspectMode?`, but `AspectMode` did not originally conform to `Codable`. Compile fix: `AspectMode` now conforms to `Codable`.
- Ratio memory: VLC ratio/aspect mode is saved per video using the same stable `video.path` / resume-key strategy as playback position. On reopen, fullscreen passes drawable size to the VLC controller so restored aspect mode applies to real VLC rendering, not only button/UI state.
- Subtitle memory is saved per video and distinguishes no saved preference, explicit Off, sidecar subtitle, and embedded subtitle track.
- Sidecar restore enables the app-rendered sidecar overlay and keeps native VLC subtitles off.
- Embedded restore saves track name plus fallback index, waits until VLC exposes tracks, retries until the chosen track can be applied, and confirms actual VLC SPU selection before latching.
- Missing saved subtitle track or missing sidecar fails safely without crash; explicit Off suppresses sidecar default and embedded auto-select; no saved preference keeps previous default behavior.
- Temporary `[VLC_PREF]` debug logs were used/kept for device verification if still present; removable after confirmation.
- Unchanged: backend, subtitle search API, video progress API, Home dashboard API shape, Downloader, Network, legal-files-only, Tailscale-private, under-10GB, quick-delete rules.

Latest iOS player audio/accessibility checkpoint:

- Changed files: `ios/PersonalCloudDownloader/Views/PlayerView.swift`, `ios/PersonalCloudDownloader/Views/VLCPlayerView.swift`.
- Root cause: hidden `MPVolumeView` was visually hidden but still exposed to iOS accessibility, causing VoiceOver/volume speech popup during volume gesture or saved-volume restore. VLC playback had no app-owned `AVAudioSession` activation, so MobileVLCKit stop/teardown could deactivate the shared audio session during fullscreen dismiss/remount or after exit, causing muted/broken audio.
- Fix: `MPVolumeView` is now hidden from accessibility on both SwiftUI and UIKit sides; saved volume restore skips redundant `setVolume` when saved volume is effectively equal to current system volume; VLC start activates `AVAudioSession` with `.playback` and `.moviePlayback` before `player.play()`; no `setActive(false)` is added on exit; temporary `[PLAYER_AUDIO]` logs were removed after cleanup.
- Unchanged: backend, APIs, Home, Downloader, Network, subtitles API, `project.yml`, player resume, subtitles, audio selector, gestures, Fit/Cover, real landscape, timeline, and progress saving.
- Status: native iOS change; requires new IPA build/install before installed app reflects the fix. Do not claim final iPhone verification unless it has already been tested on device.

Latest iOS fullscreen overlay fix checkpoint:

- Changed file: `ios/PersonalCloudDownloader/Views/PlayerView.swift`.
- Fixed locked unlock button placement: unlock now appears in the bottom safe-area region near the normal Lock slot, with a larger 52x52 tap target, so it is not hidden by the iPhone landscape bezel/corner.
- Locked touch now reveals unlock during swipe/touch start, not only at gesture end.
- Fixed sidecar subtitle manual drag by attaching high-priority drag to the actual fullscreen `SubtitleOverlay`; hit testing is disabled while locked.
- Fixed subtitle lift behavior: when bottom controls are visible, subtitle position now adds bottom chrome clearance + safe inset to the manual subtitle distance; when controls hide, subtitle returns to manual position.
- Root causes: unlock was rendered in a leading overlay instead of the bottom safe controls area; subtitle drag lost priority to fullscreen video gestures; subtitle lift used too-small fixed clearance and did not combine correctly with manual offset.
- Unchanged: `VLCPlayerView.swift`, backend, APIs, Home, Videos library, Downloader, Network, `project.yml`, top timeline, centered device clock, battery behavior, audio selector, Fit/Cover, resume/progress saving, real landscape.
- Status: Swift compile not verified on Windows; `git diff --check` passed except CRLF warning.

Latest fullscreen sidecar subtitle drag/resize checkpoint:

- Changed file: `ios/PersonalCloudDownloader/Views/PlayerView.swift`.
- Actual visible sidecar subtitle render path: `VLCPlayerController.updateCurrentCue()` -> publishes `currentSubtitleText` when sidecar `.srt` is active -> `VLCFullscreenView` body `ZStack` -> `SubtitleOverlay` -> visible `Text` in `PlayerView.swift`.
- There is no duplicate/dead fullscreen sidecar subtitle view; the inline overlay in `vlcSurface` does not mount in fullscreen.
- Root cause: subtitle drag/pinch gestures were attached to the per-cue `Text` view, but `SubtitleOverlay` only renders text while a cue is active. SRT cue gaps destroy/recreate the text view, cancelling gestures and making drag/pinch unreliable. Pinch was also too hard because the text hit area was too small.
- Fix: drag/pinch/contentShape now live on a persistent bottom-anchored subtitle strip that exists while sidecar subtitle source is active, not on the temporary cue `Text`.
- Subtitle strip has a realistic 44pt minimum grab/pinch area; visible text remains visually in the same place.
- Drag uses `highPriorityGesture` and pinch uses `simultaneousGesture` on the subtitle strip only, so parent video gestures do not steal subtitle manipulation.
- Subtitle gestures are disabled while locked.
- Stale gesture anchors reset safely when the host disappears.
- Subtitle lift uses `subtitleBottomPadding` as the single source of truth: manual distance + bottom chrome clearance when controls are visible and unlocked.
- Drag, pinch resize, and bottom-overlay avoidance now target the actual sidecar subtitle text visible during playback.
- Important limitation: if a video uses native VLC embedded subtitles instead of a sidecar `.srt`, SwiftUI cannot move, resize, or lift those subtitles because they are rendered inside the VLC drawable. Use Find subtitles / sidecar subtitles for controllable subtitle positioning.
- Unchanged: subtitle menu/search/track selection, native VLC embedded subtitle rendering, battery, lock/unlock behavior, top timeline, centered device clock, Fit/Cover, resume/progress saving, real landscape, backend/API/Home/Videos/Downloader/Network/`project.yml`.
- Status: Swift compile not verified on Windows; requires iOS build/device verification.

Subtitle gesture controls branch checkpoint:

- Branch: `feature/subtitle-gesture-controls`.
- Changed file: `ios/PersonalCloudDownloader/Views/PlayerView.swift`.
- Debug SIDE marker/yellow border was removed.
- Adjustable subtitle gesture path applies only to sidecar SwiftUI subtitles, not native VLC embedded subtitles.
- Sidecar render path: `VLCFullscreenView` -> `fsVlc: VLCPlayerController` -> sidecar `.srt` beside video -> SwiftUI `SubtitleOverlay`.
- When sidecar subtitles are active, native VLC SPU is forced off.
- Native VLC embedded subtitles render inside the VLC drawable and remain unchanged.
- Native VLC live subtitle move/resize is not safely supported: freetype styling is fixed at `VLCLibrary` init; `sub-margin` is a per-media input option set at start; MobileVLCKit exposes no reliable runtime subtitle position/size API.
- Subtitle gestures are hidden UI: no visible handles, badges, borders, sliders, or debug UI; subtitle remains plain movie-style text; drag on visible sidecar subtitle moves it up/down; pinch on visible sidecar subtitle resizes it.
- Gesture host is a persistent invisible strip around `SubtitleOverlay`, so gestures survive SRT cue gaps.
- Hit testing is enabled only when cue text is visible and player is unlocked; empty band still lets normal tap-to-controls work.
- Subtitle lift uses `controlsVisible && !isLocked`: manual distance + `safeInsets.bottom` + bottom chrome clearance while controls are visible, then returns to manual position when controls hide.
- Drag distance and text scale persist globally in `UserDefaults`, not per-video.
- Existing native embedded subtitle path still works; use Find subtitles / sidecar subtitles for adjustable subtitles.
- Unchanged: subtitle search API, native VLC embedded rendering, battery, lock/unlock, top timeline, centered clock, Fit/Cover, audio selector, resume/progress saving, real landscape, backend/API/Home/Videos/Downloader/Network/`project.yml`.
- Status: Swift compile not verified on Windows; requires Mac/iOS build verification.

Latest subtitle adjustment fix checkpoint:

- Branch: `feature/subtitle-gesture-controls`.
- Changed file: `ios/PersonalCloudDownloader/Views/PlayerView.swift` only.
- No backend change and no `VLCPlayerView.swift` change.
- Device screenshot case was native VLC embedded SPU subtitle, rendered inside VLC drawable, not the SwiftUI sidecar overlay.
- Previous drag/pinch/lift changes had no visible effect on that video because they targeted the SwiftUI sidecar overlay, while the visible subtitle was native VLC embedded.
- Native VLC embedded subtitles cannot be safely moved/resized live from SwiftUI/MobileVLCKit: freetype styling is fixed at `VLCLibrary` init; `sub-margin` is a per-media input option applied at load; no reliable runtime subtitle position/size API is exposed.
- Adjustable subtitles now use the sidecar SwiftUI overlay path only.
- Existing flows are reused: app auto-tries sidecar `.srt`; if missing, it calls existing `/api/subtitles/extract` to convert embedded text track; if extraction fails, existing Find subtitles / `/api/subtitles/search` can create/select sidecar.
- Menu sidecar entry is labeled "Subtitles (adjustable)" when appropriate.
- If user pinches while native embedded subtitle is active, app shows the existing alert once: "Use sidecar subtitles for move/resize."
- Single-renderer rule remains: enabling sidecar forces native VLC SPU off; selecting embedded track disables sidecar; never show both subtitle renderers at once.
- Sidecar gesture behavior: drag directly on subtitle text moves it vertically; pinch directly on subtitle text resizes it; gestures are disabled while locked; invisible 12pt halo around the actual text is used for touch target; taps beside subtitle text still toggle controls normally; position and scale persist globally in `UserDefaults`.
- Bottom overlay avoidance: when `controlsVisible && !isLocked`, sidecar subtitle bottom padding adds `safeInsets.bottom` + bottom chrome clearance; when controls hide, subtitle returns to manual position; `zIndex` ensures sidecar subtitle is not painted under the bottom bar/scrim.
- Clean display confirmed: debug marker/border/badge removed; no handles, sliders, boxes, or visible gesture UI; subtitle remains white centered movie-style text with existing thin black outline.
- Unchanged: backend API contracts, native VLC embedded rendering, battery, lock/unlock, top timeline, centered clock, Fit/Cover, audio selector, resume/progress saving, real landscape, Home, Videos library, Downloader, Network, `project.yml`, legal-files-only/Tailscale/private rules.
- Status: Swift compile not verified on Windows; requires Mac/iOS build verification.

Subtitle gesture cleanup checkpoint:

- Changed file: `ios/PersonalCloudDownloader/Views/PlayerView.swift`.
- Subtitle drag/resize experiment was removed because it had no visible effect on native VLC embedded subtitles.
- Removed subtitle drag/pinch state, gestures, `UserDefaults` keys, lift padding, hit-area halo, native pinch hint alert, "Subtitles (adjustable)" label, gesture host/zIndex/lift experiment code.
- Native VLC embedded subtitle path remains unchanged.
- Sidecar subtitle playback/menu/search behavior remains unchanged.
- Important lesson: tested subtitle was native VLC embedded subtitle rendered inside VLC drawable, so SwiftUI subtitle gesture changes did not affect it.
- Do not reattempt subtitle drag/resize by editing `PlayerView.swift` alone unless the app first switches to a fully app-rendered sidecar/custom subtitle path.
- Keep successful non-subtitle player overlay work intact if still present: battery safe placement, reliable lock/unlock, bottom controls backdrop.
- Unchanged: backend, APIs, `VLCPlayerView.swift`, subtitle search/extract contract, Home, Videos library, Downloader, Network, `project.yml`, top timeline, centered clock, Fit/Cover, audio selector, resume/progress saving, real landscape.
- Status: Swift compile not verified on Windows; `git diff --check` for `PlayerView.swift` passed except CRLF warning.

Real landscape:

- Real iOS fullscreen landscape works on iPhone.
- Fake VLC `rotationEffect(90°)` landscape was removed.
- `OrientationHelper` uses portrait mask for normal screens, landscape-only mask while fullscreen player is open, and portrait restore on close.
- iOS 16+ `UIWindowScene.requestGeometryUpdate` is used.
- Orientation updates target topmost presented view controller because fullscreen uses `fullScreenCover`.
- `project.yml` allows Portrait, LandscapeLeft, LandscapeRight.
- Normal tabs remain portrait.

Timeline scrub preview:

- While dragging fullscreen timeline, a floating timestamp follows slider thumb.
- Uses `MM:SS` or `H:MM:SS`.
- Timestamp disappears after release.
- Existing seek behavior is unchanged.
- Verified working on iPhone.

## 11. Current UI System

Completed redesigns:

- Home dashboard.
- Custom floating bottom navigation.
- More control hub.
- Network infrastructure monitor.
- Videos media library.
- Markdown Converter document workbench.
- Trends discovery/radar screen.
- Downloader web UI.

Visual language:

- Deep navy background.
- One restrained corner bloom.
- Flat raised surfaces.
- White low-opacity hairlines.
- Premium blue accent.
- Tinted icon chips.
- Tracked uppercase captions.
- Monospaced infrastructure labels.
- Restrained motion with Reduce Motion support.
- Avoids excessive glow and generic gradient-card dashboard style.

Bottom navigation:

- Default system tab bar replaced by custom SwiftUI floating pill bar.
- Tabs: Home, Downloader, Videos, Network, More.
- Selected-state chip uses `matchedGeometryEffect`.
- Light haptic and press feedback included.
- Accessibility labels and selected traits included.
- Custom bar respects home indicator.
- Pushed screens may need explicit bottom clearance because SwiftUI safe-area inset propagation is inconsistent.

Network UI:

- Infrastructure telemetry layout: monitor panel, summary tiles, storage, month/today metrics, daily rows, raw counters.
- Existing calculations unchanged.
- Foreground reconnect hang fixed with stale-request cancellation, refresh generation, loading reset, 750ms Tailscale wake-up wait, auto-refresh restart, inactive cancellation, and 10-second client timeout.
- Verified on iPhone.

Videos UI:

- Premium folder and folder-detail UI.
- Shows real thumbnails, progress, duration only when real duration exists, modified date when available.
- Folder grouping, thumbnails, progress, navigation, playback, and refresh behavior unchanged.

More UI:

- Form replaced by CloudBox control hub.
- Includes endpoints, privacy, Tailscale action, Trends, qBittorrent, Files, and Settings.

## 12. Current Trends Status

Purpose:

- Legal TMDB-only Trends feature.
- No torrent scraping.
- No 1337x or torrent index.
- No magnet links, info hashes, seeds, leechers, torrent links, or download links.

Backend:

- `GET /api/trends`.
- Reads only `/tmp/trends.json`.
- Does not call TMDB directly.
- Returns `{ "error": "data not available" }` if file is missing or malformed.

Script:

- Local/live script: `scripts/fetch_trends.py`.
- Reads `TMDB_API_KEY`.
- Writes `/tmp/trends.json`.
- Cron intended cadence: every 6 hours plus reboot recreation with 300-second timeout.
- Must be retested after `tmdb.env` format changed to plain assignment.

Data format:

- `updated_at`
- `global_movies`
- `global_series`
- `india_movies`
- `india_series`

Each item:

- `title`
- `poster_url`
- `rating`
- `release_year`
- `trailer_url`
- `media_type`
- `language`

Filtering:

- Global Movies merge trending, now playing, popular, and discover.
- Global Series merge trending, on the air, popular, and discover.
- Results deduplicate by TMDB `id`.
- Scoring prefers popularity, vote count, rating, recency, and weekly trending source bonus.
- Global Movies exclude dated titles older than 730 days.
- Global Series exclude old series unless TMDB provides recent activity.
- India Movies/Series use `with_origin_country=IN`, allow Hindi/English originals, and exclude regional-language originals.
- Trailer lookup prefers YouTube, official, trailer type, and English/Hindi when available.
- Reviews, clips, featurettes, teasers, reactions, interviews, songs, and promos are avoided where possible.

iOS:

- Trends screen lives under More.
- iOS calls backend only; no TMDB API key in iOS.
- Models/services live in `ios/PersonalCloudDownloader/TrendsView.swift`.
- Shows Global Movies, Global Series, India Movies, India Series.
- Cards show poster/placeholder, title, TMDB rating, release year, and Trailer button when available.
- Trailer opens in app via `SFSafariViewController` sheet.

Web:

- Web Trends lives in existing web app.
- Uses `/api/trends`.
- Existing downloader behavior unchanged.

## 13. Branch and Build Status

Current active branch:

- Working IPA branch: `feature/series-progress-fix-current-ui`.
- Base/current UI branch: `feature/video-thumbnails-v2`.

Prior completed milestone branches:

- `feature/real-landscape-player`
- `feature/home-dashboard-redesign-v2`
- `feature/timeline-scrub-time-preview`
- `feature/home-dashboard-api`
- `feature/tmdb-trends` is historical and not the current branch.

Remaining important branches after cleanup:

- `main`
- `feature/video-thumbnails-v2`
- `feature/series-progress-fix-current-ui`
- `feature/app-icon-update`

Latest series folder progress fix:

- Fix commit: `d1fd237 Fix series folder progress refresh`.
- Changed file: `ios/PersonalCloudDownloader/Views/VideosView.swift`.
- Root cause: Home opened series folders through `FolderVideosView(folder: folder, progressByPath: [:])`; `FolderVideosView` rendered from an immutable incoming progress snapshot and did not refresh progress itself, so Home-opened folders showed stale/missing watched time, progress, and duration after returning from `PlayerView`.
- Fix: `FolderVideosView` now owns local `@State refreshedProgressByPath`, seeds from incoming `progressByPath`, renders rows from `refreshedProgressByPath[video.path]`, and refreshes/merges progress on appear/return using `CompletedFilesAPI.fetchVideoProgress()` and `VLCPlayerController.localProgressSnapshot()`.
- Merge key is `video.path`; latest progress is chosen by `updatedDate`, with `timeMs` fallback.
- Impact: Home-opened series folders now update progress after watching, normal Videos tab folders still work, and no backend, API contract, HomeView, player controls, navigation, TMDB/artwork, or unrelated styling changed.

Build/deploy status:

- GitHub Actions iOS build check passed historically for simulator compile/link.
- Manual unsigned device IPA workflow passed historically for real-device archive and MobileVLCKit arm64 link.
- GitHub Actions IPA workflow is manual-only.
- Latest Home and series-grouping UI require corresponding latest IPA if not installed yet.
- Backend/frontend/docs pushes do not automatically create IPA builds.
- For current working IPA builds, use `feature/series-progress-fix-current-ui`.
- Do not use old/deleted Home dashboard v3/redesign branches for current UI builds.

## 14. Historical Milestones

- AWS MVP proved qBittorrent, Nginx file streaming, and FastAPI through Tailscale; AWS is now stopped backup only.
- Oracle A1 production migration completed; Tailscale SSH, qBittorrent, Nginx `/files/`, FastAPI, UFW, swap, storage, and budget alert were configured.
- Phase 1 backend added health, qBittorrent test, add magnet, torrents list, auto-pause, and delete-with-files.
- Simple Seedr-style web UI went live on Oracle.
- iOS app was created with SwiftUI shell, WKWebView tabs, native Home/Settings, native Videos library, AVPlayer/VLC playback, fullscreen, subtitle overlay, audio selector, and real landscape.
- GitHub Actions added simulator build check and manual unsigned device IPA build; personal iPhone install works through Sideloadly.
- Backend stabilization fixed completed-files auto-foldering, delete cleanup, subtitle sanitization, thumbnails, and network usage.
- Dynamic thumbnails were verified on iPhone.
- qBittorrent WebView was improved enough to load in app, with session-login limitation remaining.
- TMDB Trends backend/script, iOS Trends screen, and Web Trends were added as metadata-only discovery.
- CloudBox UI refresh redesigned Home, bottom nav, More, Network, Videos, Markdown Converter, Trends, and Downloader.
- Home dashboard API and TMDB artwork enrichment were deployed.
- Current production IP changed to `100.95.39.107`; older Oracle/AWS Tailscale IPs are historical only.

## 15. Current Final Status

- Oracle is production.
- AWS remains stopped as historical backup.
- Current Tailscale IP is `100.95.39.107`.
- Working: backend, web downloader, qBittorrent, Nginx/files, native iOS app, AVPlayer/VLC player, subtitles, audio selector, real landscape, Network, Trends, Markdown Converter, Home dashboard, TMDB artwork, Continue Watching, Recently Added, movie playback, and series folder navigation.
- Downloader web theme is deployed.
- Home dashboard API and TMDB artwork are deployed.
- Latest Home, current UI, and series folder progress fix require corresponding latest IPA if not installed yet.
- Everything remains private through Tailscale.

## 16. Known Follow-ups / Next Steps

- Verify latest `feature/series-progress-fix-current-ui` IPA end to end.
- Retest TMDB Trends cron after `tmdb.env` format changed from `export TMDB_API_KEY=...` to `TMDB_API_KEY=...`.
- Merge stable branches when ready.
- Keep legal-files-only, under-10GB, quick-delete policy.
- Continue manual Oracle backup/deploy discipline.
- Optional: AVPlayer cross-device resume parity.
- Optional: stronger persistent TMDB artwork cache if needed.
- Optional: clean up remaining historical notes later if they stop being useful.
