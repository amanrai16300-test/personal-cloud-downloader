# Personal Cloud Downloader Project Context

This document is the authoritative future reference for the completed CloudBox reliability and safety audit rollout. Prefer the current-state sections below over historical checkpoints. No secret, API key, password, token, private environment value, or media filename belongs here.

## 1. Project overview

- Project: Personal Cloud Downloader / CloudBox.
- Purpose: private personal cloud downloading and media streaming for legal files only.
- Access: services remain private through Tailscale.
- Download-size policy: 10GB is guidance only. CloudBox may download files larger than 10GB when storage allows. There is no automatic rejection, pause, or deletion based only on the 10GB value.
- Mandatory usage rules: legal files only, Tailscale-private access, and quick deletion after use.
- Files are not auto-deleted merely because a download completes.

## 2. Current production environment

- Provider: Oracle Cloud Always Free A1.
- AWS is stopped historical backup only.
- Hostname: `personal-cloud-downloader-vcn`.
- Current Oracle Tailscale IP: `100.95.39.107`.
- Current private Oracle IP: `10.0.0.129`.
- Access path: Tailscale only.
- OS: Ubuntu 24.04.
- Approximate capacity: 4GB RAM, 50GB boot/root disk, 100GB CloudBox storage volume.
- Oracle project directory: `/home/ubuntu/personal-cloud-downloader`; it is not a Git repository.

Current private services:

```text
FastAPI: http://100.95.39.107:8000
qBittorrent: http://100.95.39.107:8080
Web/files: http://100.95.39.107:8090
Web app: http://100.95.39.107:8090/app/
Files: http://100.95.39.107:8090/files/
```

Use only `100.95.39.107` for current Oracle work. Older Oracle and AWS Tailscale IPs are historical and must not be used for SSH, deployment, API calls, WebViews, or testing.

## 3. Security and usage rules

- Use only for legal files.
- Keep services private through Tailscale; do not expose ports 8000, 8080, or 8090 publicly.
- Never whitelist the entire Tailscale `100.64.0.0/10` range.
- Delete completed files quickly after streaming or downloading.
- 10GB is guidance only, not an enforcement threshold. Do not add rejection, pause, or deletion logic based only on that value.
- Do not store private keys, API keys, passwords, PEM contents, tokens, or secret values in this repository.

## 4. Paths and deployment rules

```text
Local backend:             backend/main.py
Live Oracle backend:       /home/ubuntu/personal-cloud-downloader/backend/main.py
Local web frontend:        frontend/app.js
Live Oracle web frontend:  /home/ubuntu/personal-cloud-downloader/backend/app.js
Local Trends script:        scripts/fetch_trends.py
Live Trends script:        /home/ubuntu/personal-cloud-downloader/scripts/fetch_trends.py
Generated Trends data:     /tmp/trends.json
Trends trailer cache:      /tmp/cloudbox-trends-trailer-cache.json
TMDB env file:             /home/ubuntu/.config/cloudbox/tmdb.env
```

- Backend deployment is manual: copy `backend/main.py`, run `python3 -m py_compile backend/main.py`, then restart `personal-downloader-api.service`.
- Web deployment is manual: copy `frontend/app.js` to live `backend/app.js`; normally no backend restart is needed.
- Trends deployment is manual: copy the script, compile it, then run it with the production environment.
- Native iOS deployment uses the manual unsigned IPA workflow and Sideloadly.
- Documentation-only changes require no Oracle deploy and no IPA build.
- Oracle deploys are manual because the live project directory is not a Git repository.

## 4A. CloudBox Reliability and Safety Audit Rollout — July 2026

Authoritative rollout checkpoint:

- Branch: `fix/cloudbox-audit-reliability`.
- Main consolidated audit commit: `17fe898`.
- Branch is pushed to GitHub.
- Oracle backend, web frontend, and Trends script were manually deployed from this branch.
- Consolidated unsigned IPA was built successfully from this branch, installed on an iPhone, and confirmed working.
- Archive compatibility compile errors were fixed in a later commit on the same branch. The later commit hash is intentionally not recorded here.
- This branch has not been documented as merged into `main`.

The current production-verified state, implemented code, remaining runtime checks, optional features, and historical experiments are separated below.

## 5. Current backend / API status

### Safe deletion and completed files

- Torrent deletion verifies actual qBittorrent content paths before deleting. It does not guess from torrent names or filename stems.
- `DELETE /api/completed-files?path=<relative-path>` deletes an exact completed file or folder using a validated relative path.
- Path traversal and paths outside the completed-download root are rejected.
- Exact sidecars, backups, temporary files, thumbnails, and saved progress are cleaned when appropriate.
- If qBittorrent removal fails but filesystem cleanup succeeds, the API returns a partial-warning result instead of claiming full success.
- Files remain user-deletable only; completion does not trigger automatic deletion.
- The loose completed-video organization guard is implemented in `backend/main.py`. Previously, `organize_loose_completed_videos()` moved every root-level video without checking whether qBittorrent was still downloading or writing it.
- Before moving loose media, the organizer now reads and validates the full qBittorrent torrent and file inventory. Matching uses resolved absolute `content_path`, `save_path`, and individual qBittorrent file paths; it does not guess from torrent names, video filenames, or filename stems.
- A qBittorrent-tracked file is safe to organize only when torrent progress is at least `1.0`, individual file progress is at least `1.0`, and torrent state is `pausedUP` or `stoppedUP`.
- Active, incomplete, checking, stalled, metadata, queued, malformed, unknown-state, and partial files are skipped. If the qBittorrent inventory cannot be read or validated, the entire organization pass fails safely without moving files.
- An untracked root video can still be organized after the complete qBittorrent inventory is read successfully and no exact path matches it. Multiple torrents matching one path combine conservatively, so one unsafe match blocks movement.
- Matching `.srt` and `.vtt` sidecars move only after the video is approved. A failure affecting one candidate does not fail `GET /api/completed-files`; `_cloudbox-thumbnails` exclusion and the completed-files API response shape are unchanged.

### Security

- CORS is restricted to `http://100.95.39.107:8090`.
- Markdown URL conversion validates DNS resolution and the actual connected peer address. Redirect targets receive the same SSRF checks.
- Private, loopback, link-local, and internal addresses remain blocked.
- TLS verification remains enabled.
- qBittorrent authentication bypass was not implemented. Do not recommend bypassing authentication or whitelisting the full Tailscale CGNAT range.

### Responsiveness and concurrency

- Blocking qBittorrent monitor calls run away from the FastAPI event loop.
- Auto-pause monitoring survives individual pass failures.
- Missing thumbnail generation uses a bounded executor: 2 workers and 32 pending jobs.
- Uncached TMDB artwork uses a bounded executor: 3 workers and 32 pending jobs.
- `/api/completed-files` and `/api/home-dashboard` do not wait for every missing thumbnail or uncached artwork request.

### Video progress

- Progress-store access is lock-protected.
- Progress paths are validated and writes are atomic.
- Progress entries are removed after successful exact file/folder deletion.
- The watched/completed threshold is 90%; the effective backend constant is `WATCHED_COMPLETION_PERCENT = 90.0`.

### Oracle production verification

Verified live backend file: `/home/ubuntu/personal-cloud-downloader/backend/main.py`.

- Backup: `backend/main.py.before-audit-fixes`.
- The deployed incomplete-file organization guard was verified in `/home/ubuntu/personal-cloud-downloader/backend/main.py`. Before deployment, the guard constant and helper were present and no unexpected `psycopg` import was present.
- The uploaded Oracle file SHA-256 was `c72c394c7d52bf0b712b029a00b4927579d6c31ec68752f5c1458195fa79f685`.
- Python compilation passed, `personal-downloader-api.service` restarted successfully, and Uvicorn completed application startup. `GET /api/health` returned `200` with `status: ok`; `GET /api/completed-files` returned `200` with valid JSON; live web polling returned `200` for both `/api/torrents` and `/api/completed-files`; no new traceback occurred after final deployment.
- `GET /api/home-dashboard` also returned valid server, library, network, Continue Watching, and Recently Added data.
- Deployment lesson: run PowerShell `scp` commands from Windows PowerShell, not inside the Oracle Bash shell. Use a unique `/tmp/` filename and verify its checksum and content before copying over the live backend.
- A stale `/tmp/main.py` was copied once and caused a temporary crash loop from an unrelated `psycopg` import. The known-good backup was restored immediately, endpoints recovered, and the correct verified guard file was then deployed. This incident is resolved.

## 6. Current iOS app and reconnect architecture

- App: CloudBox, in `ios/PersonalCloudDownloader/`.
- Stack: SwiftUI, WKWebView, URLSession/Codable, AVPlayer/AVKit, MobileVLCKit.
- Tabs: Home, Downloader, Videos, Network, More.
- qBittorrent, Files, Settings, and Trends are reached from More.

### Central endpoints

- Shared endpoint file: `ios/PersonalCloudDownloader/CloudBoxEndpoints.swift`.
- It centralizes Completed Files API, Downloader, Files, qBittorrent, Settings, Player, and VLC player endpoints.
- `project.yml` did not require changes for this centralization.

### Root reconnect

- `RootTabView.swift` coordinates reconnect state.
- Initial probes remain immediate, then approximately 750ms and approximately 2 seconds.
- While active but unavailable, retry continues approximately every 10 seconds.
- Successful recovery refreshes Home, Videos, and Network together.
- Reconnect work stops appropriately when the app becomes inactive.

### Videos

- Videos root refreshes on reconnect and after returning from Player or a folder.
- Duplicate lifecycle loads are guarded.
- Folder screens own visible video/progress state and preserve existing rows when refresh fails.
- Folder progress merges stable full relative paths with timestamp-first ordering.
- Watched status is 90% or higher.
- Videos and folder rows support Dynamic Type and improved VoiceOver grouping.
- A stale-refresh inline notice appears only for an applicable failed replacement refresh; stale generations cannot overwrite newer state.

### Network and WebViews

- Network refresh cancellation, re-entry, reconnect, and loading-state handling are fixed.
- Fractional ISO timestamps decode correctly; storage labels are accurate; daily rows have stable enumerated identity.
- Network telemetry supports Dynamic Type and VoiceOver grouping.
- Backend currently reports CloudBox storage; separate boot/root-disk presentation is optional future work.
- Failed WebViews expose a real Retry action that reloads the same persistent `WKWebView` and website data store.
- qBittorrent session login may still be lost after a full app restart.

## 7. Current Web Downloader status

- API base URL derives from `window.location.hostname`; the historical hardcoded Oracle IP is gone.
- API requests use a 15-second `AbortController` timeout with stale-controller cleanup.
- Data-generation guards prevent old poll responses from overwriting newer add/delete results.
- Torrent polling remains about every 5 seconds.
- Completed-file polling is about every 30 seconds plus initial load, manual refresh, deletion, and completion transition. Polls do not intentionally overlap.
- Duplicate Add Magnet submissions are blocked.
- API errors are normalized into concise user-safe messages; raw HTML, raw JSON, internal paths, and secrets are never displayed.
- Completed files and folders have Delete controls using the exact relative path with `DELETE /api/completed-files?path=...`.
- Delete results distinguish full success, partial success/warning, and zero deletion/failure.
- The UI reconciles with fresh server data instead of optimistically clearing all completed files.
- The completed-file delete-modal accessibility fix is implemented in `frontend/app.js`. Cancel receives initial focus; Tab and Shift+Tab remain trapped inside the open modal; Escape closes without deleting; and focus returns to the original Delete button when it still exists.
- The modal retains `role="dialog"`, its accessible name and description, and `aria-modal="true"`. Temporary keyboard listeners are removed on close, and repeated opens do not create duplicate listeners.
- Existing appearance, wording, exact-path delete API behavior, full/partial/failure handling, completed-files refresh and polling, and torrent deletion remain unchanged.
- Static verification passed: `node --check frontend/app.js` and `git diff --check`.
- This updated `app.js` has not yet been deployed or browser-verified in production.

### Oracle production verification

- Live frontend file: `/home/ubuntu/personal-cloud-downloader/backend/app.js`.
- Backup: `backend/app.js.before-audit-fixes`.
- New `frontend/app.js` was deployed.
- Downloader loaded at `http://100.95.39.107:8090/app/`; torrents and Completed Files loaded; hostname-based API calls worked.
- Completed-file Delete controls appeared.
- No important media was deleted during deployment verification.

Remaining web follow-ups are lower priority: production browser verification of delete-modal keyboard/focus accessibility, reducing full `innerHTML` rerender focus/screen-reader churn, and Web Trends refresh/staleness behavior.

## 8. Current Home dashboard and TMDB artwork

- Home uses one aggregated `GET /api/home-dashboard` response for server, library, downloads, network, Continue Watching, and Recently Added data.
- Home no longer fetches and rebuilds the entire completed-video library every 12 seconds. It uses cached completed-video data and refreshes it only when needed.
- Card tap resolution is deduplicated and cached.
- Missing/unavailable media produces a user-visible alert.
- See All / View All navigate to Videos.
- Last successful Home refresh time is persisted; stale-data age can be shown after temporary backend loss.
- Cache-first launch, generation guards, reconnect refresh, and the fixed-width Continue Watching artwork layout remain in place.
- The Continue Watching artwork width fix is included in the successfully built and installed consolidated IPA; it is no longer an unbuilt or inspection-only change.
- Displayed Home latency is request/response round-trip time including backend work; precise network-only latency wording is a possible cleanup.
- Dead/unused reconnect-state cleanup is low priority if still applicable.

TMDB artwork remains server-side metadata enrichment. Missing keys, network failures, non-200 responses, parse failures, and no matches return safely without failing the dashboard; the key is never returned to iOS.

## 9. Current Markdown Converter

- iOS validates the 25MB client-side limit before upload.
- Photos are downsampled with ImageIO to an approximately 3000px maximum dimension at approximately 0.85 JPEG quality.
- Conversion requests use generation guards; Clear invalidates stale work; duplicate submissions are blocked.
- Retry stores an immutable snapshot of the previous URL/document/photo input.
- Backend URL conversion uses the connected-peer SSRF validation described in Section 5.

Lower-priority follow-ups: copied temporary-document cleanup, malformed-success-response messaging, brittle substring-based backend error mapping, remaining Markdown Dynamic Type/accessibility polish, and background completion of a request after leaving the screen.

## 10. Current Player and progress status

### VLC progress

- Backend and local progress merge timestamp-first; an older backend snapshot cannot roll newer local progress backward.
- Pending/in-flight synchronization retains only the newest snapshot.
- Backend failure does not block playback or dismissal.
- Completion threshold is 90%; completed progress cannot be resurrected by a stale lower update.

### AVPlayer parity

AVPlayer progress/resume is implemented for `mp4`, `mov`, and `m4v`.

- Stable identity is exact backend `video.path`.
- Progress uses the existing local VLC-compatible store and merges local/backend snapshots timestamp-first.
- Resume seeks with millisecond accuracy below 90%.
- Videos at or above 90% start from the beginning.
- One 5-second periodic observer saves progress on pause, dismissal/navigation exit, and playback end.
- Observer cleanup, duplicate registration, and duplicate teardown saves are guarded.
- Backend synchronization is asynchronous; network failure cannot block playback or dismissal.
- 89.9% remains resumable; 90.0% is completed.
- VLC routing and behavior were not changed by AVPlayer parity.

### Other player behavior

- Delayed sidecar subtitle fetches cannot override a manual subtitle selection.
- Sidecar and embedded subtitle mutual exclusion remains. Native VLC embedded subtitles cannot be repositioned or resized through SwiftUI.
- Fullscreen temporarily changes brightness and restores the original value on exit.
- VLC owns an app-scoped playback audio session through fullscreen handoffs and deactivates it on final dismissal with `.notifyOthersOnDeactivation`.
- VLC `.failed` is separate from `.ended`; fullscreen failure UI has Retry and Close actions.
- Fullscreen controls have explicit VoiceOver labels and an adjustable timeline with approximately ±10-second accessibility actions.

Remaining device checks: phone-call/audio interruption recovery, real VLC network-stall classification (`.stopped` versus `.failed`), every 89.9%/90.0% boundary scenario, and every offline-to-online progress merge scenario.

## 11. Current UI system

- SwiftUI CloudBox visual language: deep navy background, raised surfaces, restrained bloom, white hairlines, blue accent, tinted icon chips, tracked captions, monospaced infrastructure labels, and Reduce Motion support.
- Custom floating tab bar: Home, Downloader, Videos, Network, More; selected traits, haptics, home-indicator clearance, and existing accessibility remain.
- More is the control hub for qBittorrent, Files, Trends, and Settings.
- Home, Network, Videos, Trends, More, Settings, Player, and folder UI received Dynamic Type and VoiceOver improvements without changing their navigation or service contracts.

## 12. Current Trends status

### Script reliability

- Trends remains legal TMDB metadata only; no torrent scraping, magnets, hashes, seeds, leechers, torrent links, or download links.
- One failing category/source/page does not abort all output. Partial successful data can still be written; if all categories fail, the previous valid file is preserved.
- Trailer cache: `/tmp/cloudbox-trends-trailer-cache.json`.
- Cache key: media type plus TMDB ID. TTL: 7 days. Cache writes are atomic. Temporary lookup failures are not cached as successful results.

### iOS and web

- Item-level tolerant decoding skips malformed items; required fields include usable title and media type.
- Trailer URLs must be HTTPS with a valid host.
- Trends UI supports Dynamic Type, accessible card summaries, explicit trailer-button labels, and four-section ordering.
- iOS calls the backend only; no TMDB key is in iOS. Trailer opens in an in-app `SFSafariViewController` sheet.
- Web Trends uses `/api/trends`.

### Production cron verification

- Cron file: `/etc/cron.d/cloudbox-trends`.
- Shell: `/bin/bash`.
- Schedule: `@reboot` after approximately 90 seconds and `0 */2 * * *` every 2 hours.
- Timeout: 300 seconds.
- Command changes into `/home/ubuntu/personal-cloud-downloader`, sources `/home/ubuntu/.config/cloudbox/tmdb.env`, then runs `/usr/bin/python3 scripts/fetch_trends.py`.
- Logs append to `/tmp/cloudbox-trends.log`.

Verified live script: `/home/ubuntu/personal-cloud-downloader/scripts/fetch_trends.py`; backup: `scripts/fetch_trends.py.before-audit-fixes`.

- Script compiled successfully.
- Exact sourced production command exited 0 with no `TMDB_API_KEY is not set` errors.
- `/tmp/trends.json` received a fresh modification time and passed JSON validation.
- Counts were 15 each for `global_movies`, `global_series`, `india_movies`, and `india_series`.
- Trailer cache was created.
- Caveat: the fallback parser was not independently verified during an unsourced test. Production verification relies on Bash sourcing the environment file first.

## 13. Branch and build status

Authoritative branch:

- `fix/cloudbox-audit-reliability`
- Main audit commit: `17fe898`.
- Later iOS archive compatibility commit exists on the same branch; its hash is not recorded here.
- Branch is pushed and tracks `origin/fix/cloudbox-audit-reliability`.
- Working tree was clean after the main push.
- Oracle deploys are manual because the Oracle directory is not a Git repository.
- IPA workflow is manual-only.
- Current consolidated IPA builds must use `fix/cloudbox-audit-reliability`.
- Do not use `feature/series-progress-fix-current-ui`, `feature/subtitle-gesture-controls`, or `feature/video-thumbnails-v2` for current builds. They may remain historical milestones.
- Do not claim this branch is merged into `main` unless that is later verified.

## 14. Historical and superseded experiments

- AWS is historical stopped backup; Oracle is current production.
- Earlier feature branches and chronological checkpoints are historical, not current build instructions.
- The subtitle drag/resize experiment was removed because the tested subtitle was native VLC embedded content rendered inside the VLC drawable. SwiftUI gesture changes could not affect it. Native embedded subtitles still cannot be moved or resized through SwiftUI; sidecar subtitle behavior remains the supported app-rendered path.
- Keep root-cause lessons from older checkpoints, but do not describe removed subtitle gestures as current functionality.

## 15. Final status

- Oracle backend, web frontend, and Trends script are deployed and production-verified.
- The consolidated IPA from `fix/cloudbox-audit-reliability` built successfully, was installed, and is working.
- Backend, Downloader, Home, Videos, folders, Player, Network, Trends, Markdown Converter, qBittorrent WebView, Files WebView, TMDB artwork, subtitles, AVPlayer/VLC progress, and reconnect infrastructure are operational.
- Everything remains private through Tailscale.
- 10GB is guidance only; legal-files-only, Tailscale-private, and quick-delete rules remain mandatory.
- Remaining work consists of edge-case runtime checks, lower-priority cleanup, and optional enrichment—not blockers for the current rollout.

## 16. Remaining follow-ups

### Runtime/configuration checks

- On the next genuine active or paused-incomplete download, confirm the loose media file remains unmoved until qBittorrent reports full torrent and file completion plus a safe terminal state (`pausedUP` or `stoppedUP`). This is runtime verification, not an implementation blocker.
- Test VLC phone calls and audio interruptions.
- Test real VLC network stalls and `.stopped` versus `.failed` reporting.
- Review actual trusted Tailscale device IPs before considering any qBittorrent login bypass; never whitelist the entire CGNAT range.

### Lower-priority code cleanup

- Production browser verification of Web delete-modal keyboard/focus accessibility.
- Web full-rerender accessibility/focus churn.
- Web Trends refresh/staleness.
- Home latency wording and dead reconnect-state cleanup.
- Markdown temporary-file and malformed-response cleanup.
- Remaining player text/warning cleanup.
- Root-disk monitoring in addition to CloudBox data-disk monitoring.

### Optional features

- Storage warnings or threshold colors.
- Playback speed and sidecar subtitle delay.
- Web pause/resume/select-file controls.
- Finished-watching delete prompt.
- Paste-image OCR.
- Monthly egress budget.
- Videos search, sort, unwatched, and Up Next.
- Separate root-disk and data-disk presentation.

Do not re-add hard 10GB enforcement as an optional feature.
