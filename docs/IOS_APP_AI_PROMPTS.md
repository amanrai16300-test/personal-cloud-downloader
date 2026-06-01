# Personal Cloud Downloader iOS App AI Prompts

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## 1. Global prompt rule

Every coding/debugging prompt should start with:

```text
Start with the most related file to this task. Stop and ask before reading any other file.
```

Use compact prompts.

Focus on one problem only.

Do not include:

```text
Commit steps
Push steps
Deploy steps
Manual browser result checking
GitHub Actions checking
Amplify checking
Unrelated future improvements
```

Unless specifically requested.

---

## 2. Prompt: create docs in repo

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Create documentation files only inside docs/ for the Personal Cloud Downloader iOS app plan.

Create:
- docs/IOS_APP_DIRECTION_LOCK.md
- docs/IOS_APP_PLAN.md
- docs/IOS_APP_ARCHITECTURE.md
- docs/IOS_APP_DESIGN_SYSTEM.md
- docs/IOS_APP_DEVELOPMENT_PHASES.md
- docs/IOS_APP_API_CONTRACT.md
- docs/IOS_APP_AI_PROMPTS.md
- docs/IOS_APP_CHECKLISTS.md

Also update docs/PROJECT_CONTEXT.md with only a short iOS app summary and references to these docs.

Do not change backend code.
Do not change frontend code.
Do not modify Nginx, systemd, Oracle server config, or deployment.
```

---

## 3. Prompt: Phase 1 iOS shell

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Fix ONLY Phase 1 of the Personal Cloud iOS app.

Goal:
Create a private SwiftUI iOS app shell with tabs:
Home, Downloader, Videos, qBittorrent, Files.

Requirements:
- Home checks backend health from http://100.92.146.101:8000/api/health.
- Downloader tab opens http://100.92.146.101:8090/app/ inside the app using WKWebView.
- qBittorrent tab opens http://100.92.146.101:8080 inside the app using WKWebView.
- Files tab opens http://100.92.146.101:8090/files/ inside the app using WKWebView.
- Videos tab is only a placeholder for now.
- Add a simple Tailscale reminder/helper in Home or Settings.
- Keep all URLs in one config file.
- Allow private HTTP access only for the Tailscale IP if iOS requires it.

Do not implement video playback yet.
Do not change existing backend/frontend.
Do not expose any port publicly.
Do not add torrent downloading on iPhone.
Do not change Oracle server config.
```

---

## 4. Prompt: Phase 2 Videos tab

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Fix ONLY the native Videos tab for the Personal Cloud iOS app.

Goal:
Create a clean watch-only video library.

Requirements:
- Call GET http://100.92.146.101:8000/api/completed-files.
- Filter video files only: .mp4, .mkv, .avi, .mov, .webm, .m4v.
- Show clean video names.
- Show empty state when no videos exist.
- Add pull-to-refresh or manual refresh.
- Tap a video to open a placeholder player screen with the stream URL.

Do not add Delete, Download, or Copy Link in Videos.
Those controls belong only in Downloader.
Do not change backend.
Do not change existing web downloader.
```

---

## 5. Prompt: Phase 3 player

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Fix ONLY the video player integration for the Personal Cloud iOS app.

Goal:
Play selected videos inside the app from existing Nginx /files/ links.

Requirements:
- Use the selected VideoItem stream_url.
- Play from http://100.92.146.101:8090/files/<filename>.
- Use VLC-style/MobileVLCKit player integration if available.
- Add basic player controls: play/pause, seek, back button, full-screen-friendly layout.
- Handle unsupported file or network failure with a simple message.

Do not copy nPlayer or VLC branding.
Do not make a separate Player tab.
Do not add file management controls in Videos.
Do not change backend.
Do not expose server publicly.
```

---

## 6. Prompt: add future /api/videos endpoint

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Fix ONLY a new backend endpoint for the iOS Videos tab.

Target:
backend/main.py

Goal:
Add GET /api/videos.

Requirements:
- Return only video files from the existing completed files/disk-based logic.
- Include: file_name, display_name, stream_url, size, modified_at, extension.
- Supported extensions: .mp4, .mkv, .avi, .mov, .webm, .m4v.
- Keep /api/completed-files unchanged.
- Do not change Downloader behavior.
- Do not change delete behavior.
- Do not change Nginx config.
```

---

## 7. Prompt: Taste Skill design

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Use Taste Skill as the design direction source.

Design ONLY the [SCREEN_NAME] screen for the Personal Cloud iOS app.

Goal:
Make it feel like a premium private iOS media/control app, not a generic AI dashboard.

Use:
- Dark mode first
- Calm private-cloud feeling
- Large touch targets
- Strong hierarchy
- Clean mobile spacing
- Native iOS-like interaction

Follow:
- docs/IOS_APP_DIRECTION_LOCK.md
- docs/IOS_APP_DESIGN_SYSTEM.md

Do not change behavior.
Do not redesign unrelated screens.
Do not move Downloader controls into Videos.
```

---

## 8. Prompt: Impeccable critique/polish

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Use Impeccable as a design reviewer.

Critique ONLY the current [SCREEN_NAME] screen.

Find:
- Generic AI design issues
- Weak spacing
- Weak hierarchy
- Inconsistent visual language
- Bad touch targets
- Poor interaction states
- Accessibility problems

Fix only the top 3 design issues.
Keep the fix minimal.
Do not redesign the whole app.
Do not change app behavior.
Do not touch unrelated screens.
```

---

## 9. Prompt: failed UI/CSS style fix

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Fix ONLY the UI issue in [TARGET_FILE].

Before changing, inspect:
- Existing class names
- Conditional class bindings
- Scoped styles
- Parent layout styles
- Duplicate UI blocks
- Responsive/media-query overrides

If the previous change did not affect the UI, do not repeat the same approach.
Find what is overriding or preventing the change.
Fix the actual conflict directly.

Do not add extra wrapper divs unless necessary.
Do not create new classes if existing classes can be corrected.
Do not touch unrelated files.
```

---

## 10. Prompt: update PROJECT_CONTEXT only

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Update ONLY docs/PROJECT_CONTEXT.md.

Add a short iOS app direction summary:
- Existing web downloader at /app/ must remain unchanged and usable from laptop/PC.
- The iOS app is an extra mobile layer, not a replacement.
- App sections: Home, Downloader, Videos, qBittorrent, Files, Settings/Tailscale helper.
- Downloader keeps full file/download management controls.
- Videos is a clean nPlayer/VLC-style watch-only library/player.
- Videos play from existing Nginx /files/ links.
- qBittorrent and Files open inside app through web views.
- Tailscale remains separate.
- Oracle remains downloader/storage/streaming server.
- iPhone must not run torrent downloading locally.
- Use SwiftUI, WKWebView, URLSession/Codable, and later MobileVLCKit/VLC-style player.
- Use Taste Skill for design creation and Impeccable for design critique/polish.
- Legal files only, Tailscale private access only.
- Reference docs/IOS_APP_DIRECTION_LOCK.md and docs/IOS_APP_DESIGN_SYSTEM.md.

Do not change code.
Do not modify any other file.
```
