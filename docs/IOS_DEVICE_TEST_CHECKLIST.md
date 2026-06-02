# iPhone Runtime Verification Checklist — Personal Cloud Downloader

**Scope:** Real iPhone runtime verification ONLY. CI compile/link success does NOT equal real device playback verified. This doc covers on-device behavior, not build correctness.

**Build / launch:**
- Open `PersonalCloudDownloader.xcworkspace` (NOT `.xcodeproj`).
- Run on a real iPhone, iOS 16.0 or later.
- Backend, Oracle, Nginx, qBittorrent, and Tailscale must already be running and unchanged.

**Live URLs (Tailscale-only):**
- Backend API: `http://100.92.146.101:8000`
- Nginx files/streaming: `http://100.92.146.101:8090/files/`
- Web app: `http://100.92.146.101:8090/app/`
- qBittorrent: `http://100.92.146.101:8080`

---

## Triage rule (read first)

If a tab or fetch fails, FIRST confirm the iPhone can reach Oracle over Tailscale:

1. iPhone Safari → `http://100.92.146.101:8090/app/`.
2. If Safari ALSO fails → problem is **network / Tailscale**, not the app. Fix network first.
3. App-bug verdict is valid ONLY when Safari reaches Oracle but the app does not.

---

## Pre-flight

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 0a | Tailscale app installed + logged in on iPhone | Status shows "Connected"; node sees `100.92.146.101` | Tailscale admin screenshot: device offline / key expired |
| 0b | iPhone can reach Oracle | Safari → `http://100.92.146.101:8090/app/` loads | Endless spinner / "cannot connect" → Tailscale down (not app bug) |

---

## WKWebView tabs

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 1 | Downloader tab → `/app/` | Web downloader renders and is interactive | White screen / ATS error in Xcode console |
| 2 | qBittorrent tab → `:8080` | qBittorrent UI renders | Login loop / blank |
| 3 | Files tab → `/files/` | Directory listing renders | 403 / blank |

**Fail evidence:** Xcode console `WKWebView` errors, `NSURLErrorDomain` code, screenshot. If Safari (0b) also fails → network, not app.

---

## Native Videos fetch

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 4 | Videos tab fetches `/api/completed-files` | Loading → list (not stuck spinner) | Error overlay; Xcode console URL + HTTP status |
| 5 | List shows completed video files | Rows with name; non-video filtered out (only `mp4/mov/m4v/mkv/avi/webm`) | Empty state while known videos exist → filter bug |
| 5b | Pull-to-refresh | Reloads list | No refresh / crash |

**Pass def (4):** HTTP 200, JSON parsed, ≥1 row when videos exist.
**Fail evidence:** Open `http://100.92.146.101:8000/api/completed-files` in Safari, save raw JSON. Confirm keys `name`, `path`, `url`, `modified_at`. (There is no `size` key — Videos hides size by design.)

---

## AVPlayer (mp4 / mov / m4v)

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 6 | Tap mp4/mov/m4v → AVPlayer route | System controls appear; video + audio play | Black frame / no audio; note exact ext + url |
| 7 | AV overlays | loading → playing; failed shows error overlay; end shows ended overlay | Wrong overlay state; screen recording |

**Pass def:** Picture + audio render; system controls affect playback; correct overlay per state.

---

## VLC player (mkv / avi / webm)

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 8 | Tap mkv/avi/webm → VLC route | Video plays | Black / stall; note ext + url |
| 9 | VLC play/pause | Toggles; frame freezes / resumes | No response |
| 10 | VLC seek slider | Drag → time jumps; playback follows | Slider snaps back / no seek |
| 11 | VLC ±10s skip | −10 goes back, +10 goes forward; time matches | Wrong delta / no-op |
| 12 | VLC overlays | loading → playing → ended correct | Stuck loading |

**Pass def:** Picture + audio render; custom controls affect playback; correct overlay per state.
**Fail evidence:** Screen recording, exact file name/ext/url, Xcode console (VLC media state logs).

---

## Fullscreen + manual landscape

Test EACH check for BOTH AVPlayer and VLC.

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 13 | Fullscreen opens | `fullScreenCover` presents; video continues | Crash / black |
| 14 | Fullscreen closes | Returns to inline screen | Stuck fullscreen |
| 15 | Inline video resumes after fullscreen (VLC drawable handoff) | Inline VLC shows picture again, not black | **Highest-risk item.** Black inline after return = drawable reclaim fail; screen recording + console |
| 16 | Manual landscape rotation in fullscreen | Rotate device → video fills landscape | No rotate / clipped |

**Note:** Orientation is zero-config — app supports landscape, user rotates device manually. Forced auto-landscape is deferred by design; do not test for it.

---

## Settings / Open Tailscale

| # | Check | Pass | Fail evidence |
|---|-------|------|---------------|
| 17 | Settings shows URLs | All live URLs listed correctly | Wrong / missing URL |
| 18 | "Open Tailscale" button (`tailscale://`) | Tailscale app opens, OR fails safe (no crash, no broken nav) | App crash / hang = fail; screenshot |

**Pass def (18):** Opens Tailscale OR no-ops gracefully. Crash = fail.

---

## Evidence kit per failure

1. Screen recording of the runtime behavior.
2. Full Xcode console log (copy as text — error domain/code, HTTP status, VLC/AV state).
3. Exact file: name, extension, `url`.
4. For data bugs: raw JSON from Safari hitting the same endpoint.
5. Device info: iOS version, model, orientation at time of failure.

---

## Must NOT change during testing

- `backend/main.py` or any backend endpoint — read-only.
- Web app, Oracle, Nginx, qBittorrent, Tailscale config.
- AVPlayer branch / VLC branch logic.
- Deployment target — keep iOS 16.0.
- No Delete/Download/Copy controls in Videos — watch-only library, not a file manager.
- No code edits, no new features — this is verify-only.
- Keep Oracle ports (8000 / 8080 / 8090) Tailscale-private — do NOT expose publicly to test.

---

## Status

Runtime / device testing is **NOT complete**. This checklist is the test plan; results are pending real-iPhone execution.
