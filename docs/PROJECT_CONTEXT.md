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
Local web files:           frontend/app.js
                           frontend/index.html
                           frontend/style.css
Live `/app/` web files:    /var/www/personal-cloud/app/app.js
                           /var/www/personal-cloud/app/index.html
                           /var/www/personal-cloud/app/style.css
Local Trends script:        scripts/fetch_trends.py
Live Trends script:        /home/ubuntu/personal-cloud-downloader/scripts/fetch_trends.py
Generated Trends data:     /tmp/trends.json
Trends trailer cache:      /tmp/cloudbox-trends-trailer-cache.json
TMDB env file:             /home/ubuntu/.config/cloudbox/tmdb.env
```

- Backend deployment is manual: copy `backend/main.py`, run `python3 -m py_compile backend/main.py`, then restart `personal-downloader-api.service`.
- Web deployment is manual: copy and verify `frontend/app.js`, `frontend/index.html`, and `frontend/style.css` together under `/var/www/personal-cloud/app/`. No backend restart is needed for these static frontend files.
- `/home/ubuntu/personal-cloud-downloader/backend/app.js` is not the file currently served by `/app/`.
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

Deletion fix checkpoint:

- Root cause: `GET /api/completed-files` organized direct-root videos as `ROOT/<stem>/<filename>`, while qBittorrent retained the stale original paths. `DELETE /api/torrents/{hash}` then removed the qB entry with `delete_files=False`, allowing the moved file to remain and consume storage.
- The first backend fix mapped the exact deterministic organizer destination and required completed-root containment, a supported regular video file, and an exact qB-recorded byte-size match. Production testing then showed that stale qB `Failed`/`0%` metadata could still reject a valid moved file.
- The final backend fix removed the stale progress requirements while continuing to reject active and moving torrents. Exact-path matching remains mandatory; no fuzzy, partial-name, recursive, or arbitrary rename matching is used.
- Existing orphan cleanup removed Governor 720p, Disclosure Day, In the Grey, Seven Snipers, and subtitle-only leftovers. CloudBox storage use fell from about 20 GB to 7.7 GB.
- Final production verification passed: delete returned `200 OK`; the torrent disappeared from `/api/torrents`; the file disappeared from `/api/completed-files`; the physical organizer folder was removed; and storage fell by the deleted file size.
- Final commit: `cfd3e83`. Status: deployed to Oracle and verified working. This was a backend-only fix; no IPA rebuild was required.

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

### Storage monitoring

- `backend/main.py` validates that `/srv/personal-cloud` is an actual mount or bind mount before reporting it as CloudBox storage.
- An existing but unmounted CloudBox directory can no longer inherit Oracle root-disk totals.
- Mount detection uses `/proc/self/mountinfo` with filesystem identity and performs a second identity check after reading usage to guard against mount-change races.
- CloudBox data storage and Oracle root storage are reported separately.
- Existing `library.storage_used_bytes` and `library.storage_total_bytes` remain CloudBox-only and backward compatible.
- `root_disk` is an optional additive response containing safe status and usage fields.
- When both targets share one filesystem, the API returns `shared_with_cloudbox` without duplicating totals.
- Missing, inaccessible, or changed storage returns safe unavailable/error states without exposing paths, raw exceptions, or internal details.
- Uploaded backend SHA-256: `ba0750cfab5e2018fd69c49e4829f05d47a2644c1028666031dd9a51008fdb02`.
- Python AST and `py_compile` checks passed. `personal-downloader-api.service` restarted and remained active, and Uvicorn completed startup successfully.
- `/srv/personal-cloud` was verified as `/dev/sdb`, ext4, and a real mount. `GET /api/home-dashboard` returned storage service available, separate CloudBox storage totals, `root_disk.status: ok`, and `same_filesystem_as_cloudbox: false`.
- No rollback was required.

## 6. Current iOS app and reconnect architecture

- App: CloudBox, in `ios/PersonalCloudDownloader/`.
- Stack: SwiftUI, WKWebView, URLSession/Codable, AVPlayer/AVKit, MobileVLCKit.
- Tabs: Home, Downloader, Videos, Network, More.
- qBittorrent, Files, Settings, and Trends are reached from More.

### Central endpoints

- Shared endpoint file: `ios/PersonalCloudDownloader/CloudBoxEndpoints.swift`.
- It centralizes Completed Files API, Downloader, Files, qBittorrent, Settings, Player, and VLC player endpoints.
- `project.yml` did not require changes for this centralization.

### iOS Downloader WebView cache-busting

- The iOS Downloader tab previously loaded the unversioned `http://100.95.39.107:8090/app/`. `DownloaderView.swift` passes `CloudBoxEndpoints.downloaderWebAppURL` through `WebScreen` to the shared `WebView`.
- The shared WebView creates `URLRequest(url:)` with the default `.useProtocolCachePolicy`. Because the HTML URL retained the same cache key after the Phase 6 web deployment, WKWebView could reuse stale `/app/` HTML and never discover the versioned CSS and JavaScript references.
- The minimal native fix changed only `ios/PersonalCloudDownloader/CloudBoxEndpoints.swift`. The Downloader URL is now `http://100.95.39.107:8090/app/?v=phase6-20260728`; no commit hash is recorded here.
- No shared WebView cache policy changed. `WKWebsiteDataStore.default()`, cookies, sessions, Retry behavior, navigation, popup handling, and every other WebView remain unchanged.
- This native endpoint change required no backend or Oracle deployment. A new IPA was built, installed, and verified on iPhone.
- The iOS Downloader tab now shows the current Phase 6 interface, including the compact `Start a download` composer, redesigned torrent cards, Delete buttons, and queue summary chips when applicable. The fix is confirmed working.

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
- Backend and the Home dashboard now distinguish CloudBox data storage from Oracle root storage.
- Failed WebViews expose a real Retry action that reloads the same persistent `WKWebView` and website data store.
- qBittorrent session login may still be lost after a full app restart.

## 7. Current Web Downloader status

### Phase 6 redesign checkpoint

- Redesign branch: `ui/cloudbox-responsive-redesign`.
- Confirmed pushed commits include `8316905` (responsive Downloader interface) and `3764b05` (status-led torrent cards). Later compact-composer, queue-summary, toast-polish, and cache-busting commits exist on the same branch; their hashes are not recorded here.
- The redesign preserves the existing single-page interface. It adds no Home, Videos, Network, or More web navigation, routes, sidebar, rail, or bottom tab bar.
- Below 760px, the Downloader form is no longer sticky. At 760px and wider, the form and queue use a readable two-column layout; the Trends entry and opened Trends view span the full grid width.
- Torrent cards use status-led 3px left rails and state-specific content: Downloading uses a blue rail, percentage, and one accessible progress bar; Waiting uses a muted rail, `Waiting for peers`, and a zero track; Completed uses a green rail and `✓ Ready — see Completed files` with no redundant bar; Failed uses a red rail and `✗ Download failed` with no empty bar.
- Torrent Delete is visually secondary, at least 44px high, and retains the existing confirmation flow. Full raw torrent hashes are not displayed in cards or delete confirmation.
- Progress uses one `role="progressbar"` representation with valid ARIA minimum, maximum, and current values.
- The compact composer uses the heading `Start a download`, a two-row magnet field, a prominent full-width Start button, and a visible Ctrl+Enter hint connected through `aria-describedby`.
- The Downloads header shows passive, non-zero summary chips for active, ready, failed, and waiting counts.
- Status feedback uses fixed success, warning, error, and offline toasts with timer ownership protection. Identical persistent offline errors are not rewritten on later five-second polls, preventing repeated live-region announcements.
- Initial queue loading shows exactly two reduced-motion-aware skeleton cards once. A torrent connectivity failure preserves and subtly dims existing cards; successful recovery restores their normal presentation.
- Existing API contracts, hostname-derived API URL, five-second torrent polling, thirty-second completed-file polling, generation guards, keyed reconciliation, focus preservation, delete-modal behavior, Completed Files, and Trends behavior remain unchanged.
- Cache-busting asset URLs are `style.css?v=phase6-20260728` and `app.js?v=phase6-20260728`.

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
- The focus-preserving rerender fix is implemented in `frontend/app.js`. Polling and refreshes previously replaced the entire torrent and completed-file containers with `innerHTML`, destroying focused controls and causing unnecessary accessibility-tree churn.
- Torrent and completed-file rows now use keyed DOM reconciliation. Unchanged rows remain mounted, while new, changed, removed, and reordered rows still update normally.
- Focus is preserved using the stable row key and control position. Completed-file delete-modal opener references are remapped when their row changes, preserving existing modal focus restoration.
- Unchanged empty states and rows are not repeatedly rewritten, reducing unnecessary screen-reader announcements.
- Polling intervals, generation guards, API behavior, ordering, design, error handling, modal behavior, and Trends remain unchanged.
- Static verification passed: `node --check frontend/app.js` and `git diff --check`.
- The updated frontend was committed, pushed, deployed to Oracle, and browser-verified.

### Web Trends refresh and staleness

- The fix is implemented in `frontend/app.js`. `trendsState.loaded` previously prevented later `/api/trends` requests, manual Refresh did not refresh Trends, and refresh/error rendering replaced valid cached content.
- Trends data becomes refresh-due after 5 minutes. Opening Trends refreshes only when due; manual Refresh forces a Trends refresh while the Trends view is visible.
- Overlapping Trends requests are prevented, at most one forced follow-up is queued, and older request responses cannot overwrite newer state.
- Stale data is shown only when the API returns `stale: true` or `updated_at` is at least 24 hours old. Missing or malformed `updated_at` does not falsely mark data stale.
- Last valid Trends cards remain visible when a background refresh fails. Unchanged Trends responses do not rebuild the cards.
- Existing design, wording, sorting, cards, endpoint, Downloader behavior, polling, modal, and focus reconciliation remain unchanged.
- Static verification passed: `node --check frontend/app.js` and `git diff --check -- frontend/app.js`.
- The change was committed, pushed, deployed to Oracle, checksum/live-file verified, and browser-verified.

### Oracle production verification

- Live URL remains `http://100.95.39.107:8090/app/`.
- The live files served by `/app/` are `/var/www/personal-cloud/app/app.js`, `/var/www/personal-cloud/app/index.html`, and `/var/www/personal-cloud/app/style.css`; Oracle served-file checksums matched the uploaded Phase 6 files.
- Browser verification confirmed that the versioned `app.js` loaded, `.dl-card` rows rendered, old `Delete torrent/files` text was absent, the queue summary displayed (for example, `5 ready`), and the compact `Start a download` composer appeared.
- The backend/API remained healthy and returned live torrent data.
- The redesign remains Tailscale-private and preserves the legal-files-only, quick-delete, and 10GB-guidance rules.

Remaining web follow-ups are lower priority: production browser verification of delete-modal keyboard/focus accessibility.

## 8. Current Home dashboard and TMDB artwork

- Home uses one aggregated `GET /api/home-dashboard` response for server, library, downloads, network, Continue Watching, and Recently Added data.
- Home no longer fetches and rebuilds the entire completed-video library every 12 seconds. It uses cached completed-video data and refreshes it only when needed.
- Card tap resolution is deduplicated and cached.
- Missing/unavailable media produces a user-visible alert.
- See All / View All navigate to Videos.
- Last successful Home refresh time is persisted; stale-data age can be shown after temporary backend loss.
- Cache-first launch, generation guards, reconnect refresh, and the fixed-width Continue Watching artwork layout remain in place.
- The Continue Watching artwork width fix is included in the successfully built and installed consolidated IPA; it is no longer an unbuilt or inspection-only change.
- The request-time wording cleanup is implemented in `ios/PersonalCloudDownloader/Views/HomeView.swift`. The foreground reconnect mode had already been removed, but remaining request timing text incorrectly described the dashboard round-trip as “latency.”
- Initial load now shows “Measuring request time,” refresh with an existing value shows “Updating request time,” failure shows “Request time unavailable,” and successful requests continue showing the measured milliseconds.
- Dead foreground-reconnect state and unreachable reconnect wording were removed. `reconnectCycle` and `reconnectRefreshToken` remain unchanged as valid refresh triggers.
- Confirmed foreground reconnect fix is implemented in `ios/PersonalCloudDownloader/Views/HomeView.swift`: the reconnect-token refresh previously hit the existing 3-second `startRefreshLoop()` dedupe guard and was swallowed.
- `startRefreshLoop(force: Bool = false)` now exists; only `.onChange(of: reconnectRefreshToken)` passes `force: true`. The forced path bypasses dedupe, cancels the pre-recovery refresh, increments the existing generation, and starts a fresh dashboard request.
- Existing generation guards prevent the cancelled request from applying stale offline or dashboard state. Normal `onAppear`, reconnect-cycle, cache-first, and 12-second polling behavior remain unchanged.
- A new IPA was built, installed, and tested on iPhone. After CloudBox remained in the background, returning later kept the user on Home and refreshed successfully. Existing reconnect indicator remains sufficient; no Oracle/backend or web deployment was required.
- Only `HomeView.swift` changed for the code fix. Home layout, cards, navigation, cache flow, API request, and Videos/Network behavior remain unchanged.
- Static verification passed: `git diff --check` and the obsolete-symbol scan.
- The change was committed as `0eccea6` and pushed to `origin/fix/cloudbox-audit-reliability`.
- `ios/PersonalCloudDownloader/Views/HomeView.swift` optionally decodes `root_disk` and the storage service status.
- The existing storage column distinguishes separate CloudBox and Oracle filesystems, a shared filesystem, CloudBox unavailable, Oracle root unavailable, and legacy cached responses without the new fields.
- New response fields are optional, so older cached dashboard JSON still decodes.
- Existing layout, cards, navigation, cache, refresh, reconnect, media actions, and API compatibility remain unchanged.
- `git diff --check` passed.

TMDB artwork remains server-side metadata enrichment. Missing keys, network failures, non-200 responses, parse failures, and no matches return safely without failing the dashboard; the key is never returned to iOS.

### Home official-poster regression resolution — August 2026

- Root cause: a fresh `GET /api/home-dashboard` response could temporarily arrive before TMDB enrichment completed, with `poster_url = nil`. During reconciliation, iOS treated that nil as authoritative and downgraded a previously known official poster to `local_thumbnail_url`. The generated video-frame screenshot then appeared until a later enriched refresh restored the official poster.
- Production fix: `ios/PersonalCloudDownloader/Views/HomeView.swift` remembers previously confirmed official artwork. After decoding a fresh dashboard response and before reconciliation, it independently merges the remembered poster and backdrop into only the corresponding missing fresh artwork fields. Fresh non-nil official artwork always wins. A generated thumbnail remains fallback only when neither fresh nor remembered official artwork exists.
- This is an iOS reconciliation fix, not a backend workaround. No Oracle deployment was required for it.
- Existing supporting behavior remains intact: `homeKnownOfficialArtworkV1` official-artwork memory, foreground artwork restoration, the persistent official-artwork disk cache, and the existing Home artwork diagnostics and in-app diagnostic viewer. Generated thumbnails remain outside the official-artwork cache.
- Relevant commit history:
  - `d2c3f48` — earlier backend bare-`Exx` episode parser fix; already deployed to Oracle and remains valid independently of the final iOS fix.
  - `4eca932` — Preserve official Home artwork during refresh.
  - `a28c6a4` — Fix Home artwork diagnostic compile error.
  - `abe4277` — Add temporary Home artwork forced test.
  - `aae841a` — Remove temporary Home artwork forced test.

### Deterministic verification evidence

- The temporary forced test applied only to the existing diagnostic Recently Added item and activated only when remembered official artwork already existed.
- After dashboard decode and before `mergingRememberedArtwork`, the test deliberately forced only the fresh poster to nil. It did not change the thumbnail, backdrop, title, IDs, grouping, progress, navigation, ordering, backend data, or any other media item.
- The test repeatedly exercised the failure condition from approximately refresh generation 2 through generation 25.
- The repeated diagnostic sequence was:

```text
forced-missing-poster-test
posterBefore=set
forcedPoster=nil
rememberedPoster=set

→ fresh-memory-merge
rawPoster=nil
rememberedPoster=set
mergedPoster=set
source=official

→ refresh-response
poster=set
source=official
```

- The first applicable reconciliation showed `reconcile-applied poster=set source=official`.
- Subsequent refreshes correctly showed `reconcile=false` because the effective official artwork no longer changed.
- No tested forced cycle downgraded to `source=thumbnail`. The production merge therefore prevented the exact known failure condition.
- Commit `aae841a` completely removed the temporary forced-test helper and all `TEMP ARTWORK FORCED TEST` code.

### Production and real-device verification

- The earlier backend parser fix in `d2c3f48` remains manually deployed and production-verified on Oracle. It is separate from the final iOS reconciliation fix.
- The final normal IPA was built from commit `aae841a` on branch `ui/cloudbox-responsive-redesign` and installed on the iPhone.
- Home worked correctly immediately. Verification passed again after more than six hours of inactivity/background time.
- On reopen, the correct official poster appeared immediately; the generated movie-scene screenshot did not appear first.
- Final status: the original long-duration Home official-poster regression is device-verified fixed.

## 9. Current Markdown Converter

- iOS validates the 25MB client-side limit before upload.
- Photos are downsampled with ImageIO to an approximately 3000px maximum dimension at approximately 0.85 JPEG quality.
- Conversion requests use generation guards; Clear invalidates stale work; duplicate submissions are blocked.
- Retry stores an immutable snapshot of the previous URL/document/photo input.
- Backend URL conversion uses the connected-peer SSRF validation described in Section 5.
- Failure-path hardening is implemented in `backend/main.py` and `ios/PersonalCloudDownloader/Views/MarkdownConverterView.swift`. Validation and cancellation paths could previously bypass temporary-file cleanup, timed-out workers could race endpoint cleanup, blank or malformed output could be treated as success, and iOS malformed responses appeared as generic network failures and could erase a valid preview.
- Converter uploads now use guarded `cloudbox-markdown-` temporary files. Pre-worker failures clean up synchronously; after launch, the worker owns cleanup on success, conversion failure, timeout, cancellation, or exception.
- Cleanup is restricted to the system temporary directory and converter-prefixed files. It cannot remove files outside that location or without the prefix.
- Empty uploads and blank, malformed, or non-string conversion results return safe `422` responses. Internal paths, tracebacks, secrets, and raw exceptions are not exposed.
- iOS maps malformed or empty successful responses to one safe conversion error before changing the preview. Failed retries preserve the last valid preview, and stale requests cannot update state or announce errors.
- VoiceOver announces the current file-conversion error once without changing focus or opening the keyboard.
- Valid document conversion, image OCR, URL conversion, limits, formatting, preview layout, and existing actions remain unchanged.
- Backend AST/compile checks and `git diff --check` passed. The changes were committed and pushed.

### Production and device verification

- `personal-downloader-api.service` was active and `/api/health` returned `200`.
- A valid text conversion returned `200` with Markdown; an empty upload returned a safe `422`; no `cloudbox-markdown-*` temporary files leaked.
- A new IPA was built, installed, and device-verified. Valid file/photo conversion worked, a failed retry preserved the preview, VoiceOver announced the error once, focus remained stable, and existing actions were unchanged.
- The same new IPA passed Home foreground reconnect verification: returning to CloudBox after backgrounding it refreshed Home without changing tabs.

Lower-priority follow-ups: brittle substring-based backend error mapping, remaining Markdown Dynamic Type polish, and background completion of a request after leaving the screen.

## 10. Current Player and progress status

### VLC progress

- Backend and local progress merge timestamp-first; an older backend snapshot cannot roll newer local progress backward.
- Pending/in-flight synchronization retains only the newest snapshot.
- Backend failure does not block playback or dismissal.
- Completion threshold is 90%; completed progress cannot be resurrected by a stale lower update.
- The compiler-warning cleanup is implemented in `ios/PersonalCloudDownloader/Views/PlayerView.swift`. Two `VLCTime.stringValue` expressions used `?? "--:--"` even though `stringValue` returns a non-optional `String`, causing unreachable nil-coalescing warnings.
- Only the two redundant fallbacks in `VLCFullscreenView.scrubTimeLabels` were removed. Playback, fullscreen controls, subtitles, audio, progress saving, resume, locking, gestures, menus, alerts, navigation, and UI remain unchanged.
- `git diff --check` passed. The change was committed as `73d90fd` and pushed to `origin/fix/cloudbox-audit-reliability`.

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

Authoritative branches:

- `fix/cloudbox-audit-reliability` remains the consolidated backend/iOS reliability branch.
- Main audit commit: `17fe898`.
- Later iOS archive compatibility commit exists on the same branch; its hash is not recorded here.
- Branch is pushed and tracks `origin/fix/cloudbox-audit-reliability`.
- Working tree was clean after the main push.
- `ui/cloudbox-responsive-redesign` is the current production-deployed Web Downloader redesign branch. Confirmed pushed commits include `8316905` and `3764b05`; later Phase 5, Phase 6, toast-polish, and cache-busting commits exist on the same branch without hashes recorded here.
- The Home poster-artwork investigation and fixes were completed on `ui/cloudbox-responsive-redesign`, which is pushed to GitHub. Relevant earlier commits include:
  - `6810443` — artwork URL added to the Home reconciliation signature.
  - `0b64067` — temporary Home artwork diagnostics.
  - `4edb511` — temporary in-app artwork log viewer.
  - `d2c3f48` — earlier bare-episode poster metadata lookup fix, manually deployed and production-verified on Oracle.
  - `4eca932` — Preserve official Home artwork during refresh.
  - `a28c6a4` — Fix Home artwork diagnostic compile error.
  - `abe4277` — Add temporary Home artwork forced test.
  - `aae841a` — Remove temporary Home artwork forced test.
- The final normal, device-verified IPA was built from `aae841a` on `ui/cloudbox-responsive-redesign`. This branch is not documented as merged into `main`.
- The final reconciliation fix was iOS-only and required no Oracle/backend update. Backend commit `d2c3f48` remains separately deployed and valid.
- Oracle deploys are manual because the Oracle directory is not a Git repository.
- IPA workflow is manual-only.
- The consolidated audit IPA history remains on `fix/cloudbox-audit-reliability`; the final verified Home-poster IPA was built from `aae841a` on `ui/cloudbox-responsive-redesign`.
- Do not use `feature/series-progress-fix-current-ui`, `feature/subtitle-gesture-controls`, or `feature/video-thumbnails-v2` for current builds. They may remain historical milestones.
- Neither current branch is documented as merged into `main`; do not claim either is merged unless that is later verified.

## 14. Historical and superseded experiments

- AWS is historical stopped backup; Oracle is current production.
- Earlier feature branches and chronological checkpoints are historical, not current build instructions.
- The subtitle drag/resize experiment was removed because the tested subtitle was native VLC embedded content rendered inside the VLC drawable. SwiftUI gesture changes could not affect it. Native embedded subtitles still cannot be moved or resized through SwiftUI; sidecar subtitle behavior remains the supported app-rendered path.
- Keep root-cause lessons from older checkpoints, but do not describe removed subtitle gestures as current functionality.

## 15. Final status

- Oracle backend, web frontend, and Trends script are deployed and production-verified.
- Backend storage separation is deployed and production-verified.
- The consolidated IPA from `fix/cloudbox-audit-reliability` built successfully, was installed, and is working.
- The latest Home foreground reconnect fix is built, installed, and iPhone-verified.
- The August 2026 long-duration Home official-poster regression is fixed in iOS and device-verified, including after more than six hours of inactivity/background time.
- Backend, Downloader, Home, Videos, folders, Player, Network, Trends, Markdown Converter, qBittorrent WebView, Files WebView, TMDB artwork, subtitles, AVPlayer/VLC progress, and reconnect infrastructure are operational.
- Everything remains private through Tailscale.
- 10GB is guidance only; legal-files-only, Tailscale-private, and quick-delete rules remain mandatory.
- Remaining work consists of edge-case runtime checks, lower-priority cleanup, and optional enrichment—not blockers for the current rollout.

## 16. Remaining follow-ups

### Home artwork diagnostic cleanup

- Low priority only: later remove `[HomeArtworkDiag]` logging and the in-app artwork diagnostic viewer if they are no longer useful.
- Diagnostic cleanup is not a blocker and does not reopen the device-verified fixed poster issue.
- Any cleanup must preserve `homeKnownOfficialArtworkV1`, foreground artwork restoration, the persistent official-artwork disk cache, fresh-over-remembered official-artwork precedence, generated-thumbnail fallback, cache-first launch, generation guards, forced reconnect refresh, 12-second Home polling, offline cached data, navigation, card layout, and Continue Watching behavior.

### Runtime/configuration checks

- On the next genuine active or paused-incomplete download, confirm the loose media file remains unmoved until qBittorrent reports full torrent and file completion plus a safe terminal state (`pausedUP` or `stoppedUP`). This is runtime verification, not an implementation blocker.
- Test VLC phone calls and audio interruptions.
- Test real VLC network stalls and `.stopped` versus `.failed` reporting.
- Review actual trusted Tailscale device IPs before considering any qBittorrent login bypass; never whitelist the entire CGNAT range.

### Lower-priority code cleanup

- Production browser verification of Web delete-modal keyboard/focus accessibility.
- Remaining player text cleanup.

### Optional features

- Storage warnings or threshold colors.
- Playback speed and sidecar subtitle delay.
- Web pause/resume/select-file controls.
- Finished-watching delete prompt.
- Paste-image OCR.
- Monthly egress budget.
- Videos search, sort, unwatched, and Up Next.

- Build and install a new IPA and verify Home shows separate CloudBox and Oracle root totals, preserves legacy cached-response loading, and leaves other Home behavior unchanged.

Do not re-add hard 10GB enforcement as an optional feature.
