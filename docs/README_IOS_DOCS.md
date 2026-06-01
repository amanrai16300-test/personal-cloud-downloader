# Personal Cloud Downloader iOS Documentation Pack

Created: 2026-06-01  
Project: Personal Cloud Downloader  
Repo path on Windows: `C:\my space\Projects\cloud_download`

---

## Purpose

This docs pack is for the future private iOS companion app for the existing Personal Cloud Downloader.

The goal is to avoid wrong direction, generic AI design, or accidental breaking of the current working downloader.

---

## Recommended docs folder

Put these files inside your project:

```text
C:\my space\Projects\cloud_download\docs\
```

Recommended final structure:

```text
docs/
├─ PROJECT_CONTEXT.md
├─ IOS_APP_DIRECTION_LOCK.md
├─ IOS_APP_PLAN.md
├─ IOS_APP_ARCHITECTURE.md
├─ IOS_APP_DESIGN_SYSTEM.md
├─ IOS_APP_DEVELOPMENT_PHASES.md
├─ IOS_APP_API_CONTRACT.md
├─ IOS_APP_AI_PROMPTS.md
└─ IOS_APP_CHECKLISTS.md
```

This pack also includes:

```text
PROJECT_CONTEXT_IOS_UPDATE.md
```

That file is not meant to replace `PROJECT_CONTEXT.md`.  
It contains the exact short section to copy into the existing `docs/PROJECT_CONTEXT.md`.

---

## What each file is for

| File | Purpose |
|---|---|
| `IOS_APP_DIRECTION_LOCK.md` | Keeps the project from going in the wrong direction |
| `IOS_APP_PLAN.md` | Full feature plan and screen responsibilities |
| `IOS_APP_ARCHITECTURE.md` | Technical architecture, stack, folders, app flow |
| `IOS_APP_DESIGN_SYSTEM.md` | Professional UI direction to avoid generic AI design |
| `IOS_APP_DEVELOPMENT_PHASES.md` | Safe step-by-step build phases |
| `IOS_APP_API_CONTRACT.md` | Backend endpoints and expected response shapes |
| `IOS_APP_AI_PROMPTS.md` | Copy-paste prompts for coding/design tools |
| `IOS_APP_CHECKLISTS.md` | Pre-build, design, safety, testing, and do-not-change checklists |
| `PROJECT_CONTEXT_IOS_UPDATE.md` | Small section to add to the existing project context |

---

## Important project rule

The existing web downloader must stay available for laptop/PC:

```text
http://100.92.146.101:8090/app/
```

The iOS app is an extra mobile layer, not a replacement.

---

## Final app concept

```text
One private iOS app
├─ Home / Dashboard
├─ Downloader
├─ Videos
├─ qBittorrent
├─ Files
└─ Settings / Tailscale Helper
```

Main rule:

```text
Downloader = manage downloads/files
Videos = watch videos only
qBittorrent = advanced torrent control
Files = raw Nginx file browser
Tailscale = separate app/helper only
Oracle = downloader/storage/streaming server
```

Legal files only.  
Private through Tailscale only.
