# Personal Cloud Downloader iOS App Design System

Created: 2026-06-01  
Project: Personal Cloud Downloader

---

## 1. Purpose

This file exists to prevent generic AI-looking design.

The app should feel:

```text
Private
Modern
Calm
Premium
Utility-focused
Mobile-first
Media-friendly
Native iOS-like
```

It should not feel like a random AI SaaS dashboard.

---

## 2. Design quality tools

Use these tools/repos as design helpers:

```text
Taste Skill = design creation / redesign guide
Impeccable = design critique / polish / harden doctor
```

### Taste Skill role

Use Taste Skill when creating or redesigning a screen.

Use it for:

```text
Home dashboard
Videos library
Video player screen
Settings/Tailscale helper
Mobile UI hierarchy
Typography
Spacing
Color direction
Premium UI feeling
```

### Impeccable role

Use Impeccable after the UI exists.

Use it for:

```text
Audit
Critique
Polish
Harden
Find generic AI design
Fix spacing problems
Fix hierarchy problems
Fix color imbalance
Fix weak interaction states
```

---

## 3. Correct design workflow

Do not redesign the entire app at once.

Use this order:

```text
1. Build simple working screen
2. Apply Taste Skill design guidance
3. Run Impeccable critique
4. Fix only top 3 design issues
5. Run Impeccable polish/harden if needed
6. Move to next screen
```

Screen order:

```text
Home
↓
Videos
↓
Video Player
↓
Settings / Tailscale Helper
↓
Downloader wrapper
↓
qBittorrent wrapper
↓
Files wrapper
```

---

## 4. Visual personality

The app should feel like:

```text
A private media command center
A polished iOS utility
A calm personal cloud app
A premium video/file control app
```

Do not make it feel like:

```text
Crypto dashboard
Generic SaaS admin panel
Over-glowing gamer UI
Random AI card layout
Marketing landing page
Corporate enterprise portal
```

---

## 5. Color direction

Recommended direction:

```text
Dark mode first
Deep navy / black background
Soft blue for primary actions
Green for online/safe status
Amber for warnings
Red only for delete/danger
Low-border glass/card surfaces
```

Avoid:

```text
Too many gradients
Too many neon glows
Random rainbow colors
High-saturation backgrounds
Unreadable low-contrast text
```

---

## 6. Typography direction

Use:

```text
Large clear screen titles
Readable body text
Small muted metadata
Strong file names
Clean tab labels
No oversized marketing headings inside app
```

Hierarchy:

```text
Screen title = strongest
Section title = medium
File/video name = readable and strong
Metadata = small and muted
Actions = clear labels
```

---

## 7. Spacing and layout rules

Use:

```text
Large touch targets
Comfortable card spacing
Consistent padding
Clean section gaps
No cramped file rows
No tiny buttons
No dense desktop table layout on iPhone
```

Avoid:

```text
Too many cards on one screen
Unaligned buttons
Mixed border radius styles
Tiny text
Buttons wrapping badly
Long filenames destroying layout
```

---

## 8. Component rules

### Cards

Cards should be:

```text
Soft
Calm
Readable
Not too shiny
Not too nested
```

### Buttons

Button hierarchy:

```text
Primary = main action
Secondary = normal action
Danger = delete only
Ghost = low-priority action
```

Never make delete look like a normal action.

### Video rows

Video rows should show:

```text
Clean display name
Optional small metadata
Optional progress/resume indicator
No delete/copy/download buttons
```

### Downloader rows

Downloader rows can show:

```text
File name
Size
Date/time
Stream
Download
Copy VLC link
Delete
```

---

## 9. Screen-specific design direction

### Home

Should feel like:

```text
Simple server command center
```

Show:

```text
Server status
Tailscale reminder
Active downloads count
Completed videos count
Quick actions
```

Do not overload it with charts.

### Downloader

Should preserve the current web UI.

If later redesigned natively, keep it practical, not media-library style.

### Videos

Should feel like nPlayer/VLC inspired.

Show:

```text
Continue watching
Recently added
Clean list
Search later
Tap to play
```

No file management clutter.

### Video Player

Should feel immersive.

Use:

```text
Full-screen video area
Minimal top bar
Bottom controls
Seek bar
Forward/back
Speed
Subtitle
Audio
Fit
Lock
```

Do not copy nPlayer exactly.

### qBittorrent

This is advanced/debug control.

It can remain web UI inside app.

Do not over-design it in Phase 1.

### Files

This is raw file browser.

Keep it separate from Videos.

---

## 10. Anti-generic AI checklist

Before accepting a design, ask:

```text
Does this look like a real iOS app?
Does each screen have one clear purpose?
Are the actions obvious?
Are dangerous actions visually separated?
Is Videos clean and watch-only?
Is Downloader clearly management-focused?
Does the UI avoid random generic cards?
Is spacing consistent?
Does it look good with long filenames?
Does it work on one hand/touch usage?
```

Reject designs that:

```text
Use random blue-purple gradients everywhere
Have too many dashboard cards
Use generic "Welcome back" hero sections
Hide important actions
Put delete buttons in Videos
Mix desktop and mobile layouts
Look like a copied SaaS template
```

---

## 11. Taste Skill prompt pattern

Use Taste Skill like this:

```text
Use Taste Skill as the design direction source.

Design ONLY the [screen name] screen for the Personal Cloud iOS app.

Goal:
Make it feel like a premium private iOS media/control app, not a generic AI dashboard.

Keep:
- Dark mode first
- Calm premium utility style
- Large touch targets
- Clear hierarchy
- No unnecessary marketing sections

Do not change:
- Existing web downloader behavior
- Screen responsibilities from IOS_APP_DIRECTION_LOCK.md
```

---

## 12. Impeccable prompt pattern

Use Impeccable like this:

```text
Use Impeccable as a design reviewer.

Critique ONLY the current [screen name] screen.

Find:
- Generic AI design issues
- Weak spacing
- Weak hierarchy
- Bad interaction states
- Inconsistent visual language
- Accessibility/touch target problems

Fix only the top 3 issues.
Do not redesign the whole app.
Do not change behavior.
```

---

## 13. Final design rule

Professional design comes from:

```text
Direction lock
+
Design system
+
Taste Skill creation
+
Impeccable critique
+
Small controlled fixes
```

Do not ask AI to “make everything modern” without these constraints.
