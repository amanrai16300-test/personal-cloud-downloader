# Unsigned Device IPA Plan — Personal Cloud Downloader iOS App

**Scope:** The safest GitHub Actions path to produce a downloadable **unsigned** real-iPhone IPA artifact, for personal install with Sideloadly/AltStore on Windows. No Apple signing in CI yet.

---

## Core question

Can GitHub Actions create an unsigned device IPA that Sideloadly/AltStore can sign and install on a real iPhone?

## Key answer

**Yes** — build a real **device** `.app` with `CODE_SIGNING_ALLOWED=NO`, then **manually repack** it into `Payload/*.app` → zip → `.ipa`.

Do NOT use `xcodebuild -exportArchive` — it requires signing and fails without certs. The manual Payload-zip trick avoids signing entirely. Sideloadly signs later, on Windows, with a free Apple ID.

---

## Simulator build vs real device build

| | Current (simulator) | Needed (device) |
|--|--|--|
| Destination | `generic/platform=iOS Simulator` | `generic/platform=iOS` |
| CPU slice | simulator | arm64 device |
| SDK | `iphonesimulator` | `iphoneos` |
| Output | simulator `.app` | device `.app` |
| Signing | none | none in CI (Sideloadly signs later) |
| Installable on iPhone | NO | YES (after sideload sign) |

### Why the current simulator build cannot install on iPhone

The existing `iOS Build Check` workflow builds for `generic/platform=iOS Simulator`. That output is a **simulator slice** — it runs only in the iOS Simulator, never on a physical iPhone. A real device needs the `iphoneos` SDK and an **arm64 device** slice. That is a different build, which is why a separate device workflow is required.

---

## MobileVLCKit device arm64 slice risk

- The device build must link a **MobileVLCKit arm64 device** slice, not a simulator-only slice.
- MobileVLCKit 3.6.0 is pulled prebuilt via CocoaPods. The standard pod includes the device arm64 slice, so it should link.
- **Risk:** a passing simulator compile does NOT prove the device link. Some VLC builds are fat/xcframework and can fail device linking if a slice is missing or there is a bitcode mismatch.
- **This is the real unknown.** The first device archive/link step is the true test of MobileVLCKit on device.

---

## Recommended future workflow (do NOT create yet)

- A **separate** `workflow_dispatch`-only workflow (manual trigger; does not run on every push).
- **Do not replace** the existing `iOS Build Check` workflow — keep it as the compile gate.

Steps:

```text
- checkout
- install xcodegen if missing
- xcodegen generate
- pod install
- xcodebuild archive for generic iOS device:
    -workspace PersonalCloudDownloader.xcworkspace
    -scheme PersonalCloudDownloader
    -configuration Release
    -destination 'generic/platform=iOS'
    -archivePath build/PCD.xcarchive
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
    ONLY_ACTIVE_ARCH=NO
- manual repack into unsigned IPA:
    mkdir -p Payload
    cp -R build/PCD.xcarchive/Products/Applications/PersonalCloudDownloader.app Payload/
    zip -r PersonalCloudDownloader-unsigned.ipa Payload
- upload artifact: PersonalCloudDownloader-unsigned.ipa
```

Signing stays disabled. No Apple secrets in CI.

---

## Artifact

- Produced: `PersonalCloudDownloader-unsigned.ipa` — unsigned, device arm64, downloadable from the Actions run.
- Fallback: if the IPA repack is flaky, ship a raw `.app` zip instead. Sideloadly accepts a `.app` too.

---

## How Sideloadly/AltStore uses it (Windows)

1. Download the unsigned `.ipa` artifact on Windows.
2. Open Sideloadly; plug in the iPhone via USB.
3. Enter a free Apple ID — Sideloadly injects signing + the iPhone's provisioning at install time.
4. App installs on the device. **7-day expiry**, re-sign weekly.
5. AltStore variant = same flow + AltServer auto-refresh weekly.

CI never signs. The Apple ID stays on the Windows machine, not in repo secrets — safer (no certs/secrets in the repo).

---

## Risks / likely failure points

| Risk | Why | Mitigation |
|--|--|--|
| MobileVLCKit device link fail | simulator pass ≠ device arm64 link | first real test; check pod slice / xcframework if it fails |
| `-exportArchive` signing block | requires certs | do NOT use it; manual Payload zip instead |
| Archive wants signing | Release signs by default | `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` |
| IPA rejected by Sideloadly | bad repack | fallback: ship raw `.app` zip |
| 7-day expiry | free Apple ID limit | weekly re-sign / AltStore auto-refresh |
| Bundle ID conflict at sign | Sideloadly may rewrite | let Sideloadly set its own; `project.yml` bundle ID change deferred |
| Debug vs Release | Debug is heavier | use Release config for the install build |

---

## Recommended next implementation step

One concern only: add a **separate** `workflow_dispatch`-only workflow that archives the **device** build unsigned, repacks the IPA, and uploads the artifact. Leave the existing simulator `iOS Build Check` untouched as the compile gate.

The first real milestone is confirming **MobileVLCKit links for device arm64** — the unknown the simulator build never proved.

## Order

```text
1. Add a separate unsigned device IPA workflow.
2. Run it manually (workflow_dispatch).
3. Confirm MobileVLCKit device link succeeds.
4. Download the artifact.
5. Install with Sideloadly (free Apple ID, Windows).
6. Run docs/IOS_DEVICE_TEST_CHECKLIST.md.
```

---

## Status

This is a plan only. No workflow created, no `project.yml` change, no bundle ID change, no code change, no backend/web/Oracle/Nginx/qBittorrent/Tailscale change, no new iOS feature. Device link, unsigned IPA, install, and runtime/device testing all remain pending.
