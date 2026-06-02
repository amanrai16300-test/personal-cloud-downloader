# Personal iPhone Install Plan — Personal Cloud Downloader iOS App

**Scope:** How to install this iOS app on your own iPhone for personal use, without owning a Mac.

---

## Constraint

- You do NOT own a Mac.
- GitHub Actions iOS compile/link check already passes (XcodeGen, CocoaPods, MobileVLCKit 3.6.0, `xcodebuild` simulator compile).
- Goal: run the app on your own iPhone personally.

## Key fact

The GitHub Actions **macOS runner is a real Mac**. It can build (and, with Apple credentials, sign) the app. So "no Mac locally" does NOT mean "no Mac" — CI is your Mac for building.

The remaining gap is **signing + installing on the device**, not building. CI cannot push to your phone directly; you download an IPA and install it with a tool.

---

## Option 1: Apple Developer Program + GitHub Actions signed IPA

| Item | Detail |
|------|--------|
| Apple account | Paid Apple Developer Program, $99/yr |
| Local Mac | NO — CI runner signs |
| Cert type | Apple Development (or Ad Hoc Distribution) |
| Provisioning | Development or Ad Hoc profile with your iPhone UDID registered |
| App lifetime | ~1 year (cert/profile expiry); no weekly re-sign |
| Device limit | 100 devices per type per year |
| Install | IPA artifact → sideload with AltStore / Sideloadly on Windows |

**Files / secrets (GitHub repo secrets):**
- `.p12` signing cert (base64) + password
- `.mobileprovision` profile (base64) with your iPhone UDID
- Team ID
- `ExportOptions.plist` (signing style, team, method)

**CI can:** archive → export signed IPA → upload artifact.
**CI cannot:** install on phone directly. You download the IPA and sideload it. With a paid dev cert, validity is ~1 year (no weekly re-sign).

---

## Option 2: TestFlight

| Item | Detail |
|------|--------|
| Apple account | Paid Developer Program ($99) required |
| Local Mac | NO — CI uploads |
| Build type | App Store Distribution signed, uploaded to App Store Connect |
| Install | TestFlight app on iPhone, tap install — no sideload tool |
| App lifetime | 90 days per build; re-upload to renew |
| Extra | App Store Connect record + bundle ID; internal testers = no review |

**Files / secrets:** App Store Connect API key (`.p8` + key ID + issuer ID), distribution cert `.p12`, App Store provisioning profile, app record bundle ID.
**CI can:** build → sign → upload via `altool` / `notarytool` / Fastlane `pilot`.
**Best install UX.** Internal testing = just you, no review wait. Needs bundle ID registered + app record created once (web, no Mac).

---

## Option 3: Remote Mac (MacinCloud / MacStadium / Scaleway Mac)

| Item | Detail |
|------|--------|
| Apple account | Still need Apple Developer for device install |
| Local Mac | NO — rent a cloud Mac |
| Use | Manual Xcode signing/install over the rented Mac |
| Cost | Hourly/monthly rent ON TOP of $99 |

**Verdict:** Redundant. GitHub Actions already gives a free Mac for CI. Rent a Mac only if you later need interactive Xcode debugging / Instruments on a device. Not needed for install. Skip for now.

---

## Option 4: Free Apple ID + Sideloadly / AltStore

| Item | Detail |
|------|--------|
| Apple account | Free Apple ID ("Personal Team") |
| Local Mac | Not needed — Sideloadly / AltStore on Windows |
| App lifetime | 7 days, re-sign weekly |
| Device limit | 3 apps, limited devices |
| Cost | $0 |

**How it works:** CI builds the IPA; Sideloadly (Windows) signs it with your free Apple ID at install time and installs to the iPhone over USB. No $99, no Mac.

**Two flavors:**
- 4a. CI builds unsigned IPA → Sideloadly signs with free Apple ID → install. 7-day expiry, re-sign manually.
- 4b. Same, but AltStore auto-refresh weekly (needs AltServer running on a PC in the background).

**Catch:** 7-day expiry means weekly re-sign. Fine for solo personal use.

---

## What GitHub Actions can do

- Build the app on a macOS runner.
- Optionally sign the app (with Apple credentials in repo secrets).
- Produce a downloadable IPA artifact.
- For TestFlight: upload the signed build to App Store Connect.

## What GitHub Actions cannot verify

CI compile pass does NOT equal runtime verified. CI cannot verify:
- Real iPhone playback (AVPlayer, VLC).
- Fullscreen + VLC drawable handoff at runtime.
- Tailscale runtime reach from the app.
- Manual landscape feel.
- Install/launch on an actual device.

## Runtime/device testing still required

After install on a real iPhone, runtime/device testing is still required using `docs/IOS_DEVICE_TEST_CHECKLIST.md`. CI compile success ≠ real iPhone playback verified.

## Bundle ID note (future signing)

Any paid signing path needs a stable bundle ID. Pick a reverse-DNS ID, e.g. `com.<you>.personalclouddownloader`, set later in `ios/project.yml`. Not changing `project.yml` now — note for the future signing step.

---

## Recommendation

1. **Now — Option 4 (Free Apple ID + Sideloadly on Windows).**
   - $0, no Mac, install this week.
   - Cost: re-sign every 7 days. Acceptable for solo personal use.
   - Fastest cheap path to run the device checklist.

2. **Later — Option 1 (paid $99 + CI-signed IPA, install via AltStore/Sideloadly)** only if 7-day re-signing becomes annoying.
   - ~1-year validity, no weekly re-sign.

- Skip Option 3 (remote Mac) — redundant; CI covers build.
- Option 2 (TestFlight) — best UX but needs paid + app record; pick only if you want tap-to-install or to share later.

## Final decision rule

Try free Sideloadly first to validate runtime cheaply. Upgrade to the $99 Apple Developer Program only if the 7-day re-sign churn becomes annoying.

---

## Status

This is a plan only. No signing workflow created, no `project.yml` change, no code change, no backend/web/Oracle/Nginx/qBittorrent/Tailscale change, no new iOS feature. Runtime/device testing remains pending.
