# Oracle Storage Migration Runbook, CloudBox

Created: 2026-06-08  
Project: CloudBox / Personal Cloud Downloader  
Purpose: Safely move CloudBox to a storage layout that protects the app and allows downloaded video data to survive if the VM instance breaks, while staying inside Oracle Always Free limits.

---

## 1. Final Target Layout

Final desired Oracle layout:

```text
50GB boot volume
100GB separate block volume mounted at /srv/personal-cloud
Total Oracle Block Volume storage used: 150GB
```

This is the target because:

- Boot volume should hold only Ubuntu, CloudBox app code, packages, services, configs, and small app state.
- Separate block volume should hold CloudBox runtime storage under `/srv/personal-cloud`.
- If the VM instance breaks but the separate block volume survives, the data volume can be attached to a new VM and mounted again at `/srv/personal-cloud`.
- Video files are not backed up to Object Storage.
- App brain is backed up separately.

Final structure:

```text
Boot volume, 50GB
├── Ubuntu
├── Python / FastAPI dependencies
├── qBittorrent app
├── Nginx
├── CloudBox app code
├── systemd services
├── Tailscale
└── app-only backup scripts

Separate block volume, 100GB
└── /srv/personal-cloud
    ├── downloads/complete
    ├── downloads/incomplete
    ├── generated .srt / .vtt subtitle files
    ├── generated thumbnails
    └── temporary video runtime files
```

---

## 2. Free Tier Safety Rules

Oracle Always Free Block Volume rule:

```text
Boot volumes + block volumes combined must stay at or below 200GB total.
```

Oracle Always Free includes:

```text
200GB total Block Volume storage
5 total volume backups
Default compute boot volume around 50GB
```

Reference:

```text
Oracle Always Free Resources documentation:
https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
```

Final target is safe:

```text
50GB boot + 100GB data block volume = 150GB total
```

This leaves about 50GB headroom inside the 200GB Always Free Block Volume limit.

---

## 3. Current Risk

Current known Oracle setup:

```text
Current VM boot volume: about 100GB
Current root filesystem: about 96GB
Current app path: /home/ubuntu/personal-cloud-downloader
Current download path: /srv/personal-cloud/downloads
Current access: Tailscale
```

Important current deployment detail:

```text
/home/ubuntu/personal-cloud-downloader is NOT a Git repo.
Do not run git pull there.
Use clone-copy deploy from /tmp when deploying.
```

Current live paths:

```text
Backend live:
/home/ubuntu/personal-cloud-downloader/backend/main.py

Web frontend live:
/home/ubuntu/personal-cloud-downloader/backend/app.js

Trends script live:
/home/ubuntu/personal-cloud-downloader/scripts/fetch_trends.py

TMDB env:
/home/ubuntu/.config/cloudbox/tmdb.env
```

Because the current boot volume is already 100GB, do not try to shrink it directly. The clean path is a new VM with a 50GB boot volume.

---

## 4. Critical Do-Not-Cross-Free-Tier Rule

Do not create this combination:

```text
Old current boot volume: 100GB
New boot volume: 50GB
New data block volume: 100GB
Total: 250GB
```

That can cross the 200GB Always Free Block Volume limit.

Safe migration storage math:

```text
Phase A:
Old boot 100GB only = 100GB total

Phase B:
Old boot 100GB + new boot 50GB = 150GB total

Phase C, after old boot is deleted:
New boot 50GB only = 50GB total

Phase D:
New boot 50GB + new data block 100GB = 150GB total
```

Do not create the 100GB separate block volume until the old 100GB boot volume has been deleted, unless Oracle Console clearly confirms total Block Volume usage will remain inside Always Free limits.

---

## 5. What Must Be Protected

This migration protects the CloudBox app brain.

Back up these before touching the current VM:

```text
/home/ubuntu/personal-cloud-downloader
/home/ubuntu/.config/cloudbox
/etc/systemd/system/personal-downloader-api.service
/etc/systemd/system/qbittorrent*.service
/etc/nginx/sites-available
/etc/nginx/sites-enabled
/home/ubuntu/.config/qBittorrent
/home/ubuntu/.local/share/qBittorrent
/var/lib/cloudbox
```

Also save a small system package/service reference:

```bash
dpkg --get-selections > /tmp/cloudbox-installed-packages.txt
systemctl list-unit-files > /tmp/cloudbox-systemd-units.txt
```

Include those two files in the app-only backup if created.

Important features that must survive:

```text
FastAPI backend
Web app
qBittorrent config
Nginx private streaming config
systemd service files
TMDB Trends script and env reference
Network dashboard backend endpoint
Subtitle backend extraction endpoint
Subtitle sanitizer logic
Thumbnail generation logic
iOS-compatible API behavior
video progress / resume data
future cloudbox.db data
```

---

## 6. What Must Not Be Backed Up to Object Storage

Do not include downloaded video data in app-only backup:

```text
/srv/personal-cloud/downloads/complete
/srv/personal-cloud/downloads/incomplete
large .mp4 files
large .mkv files
large .avi files
large torrent folders
```

Generated runtime files do not need long-term Object Storage backup:

```text
generated .srt / .vtt subtitle files
generated .srt.bak / .vtt.bak files
generated thumbnail jpg files
timeline thumbnail cache
incomplete downloads
```

These files belong to the video runtime storage. After migration, they should live on the separate 100GB block volume under `/srv/personal-cloud` and should be deleted together when the related video/torrent is deleted.

---

## 7. Backup Strategy

Use two different protection layers.

### 7.1 App-only backup

Purpose:

```text
Restore CloudBox app/server/settings/features after VM failure.
Does not restore old downloaded video files.
```

Backup target:

```text
OCI Object Storage bucket, small app-only backup
```

Expected size:

```text
Small, usually far below 20GB if videos are excluded.
```

Suggested backup name format:

```text
cloudbox-app-backup-YYYY-MM-DD-HHMM.tar.gz
```

Example contents:

```text
CloudBox app code
TMDB env/config folder
qBittorrent settings
Nginx config
systemd services
cloudbox.db if present
package list
service list
```

### 7.2 Separate block volume

Purpose:

```text
Keep /srv/personal-cloud separate from the VM boot disk.
If the VM breaks but the block volume survives, attach it to a new VM.
```

This is not a true backup. It protects against VM loss, not against block volume deletion, filesystem corruption, or accidental deletion.

---

## 8. Migration Plan

### Phase 0, current VM safety check

Before doing anything, confirm current services:

```bash
curl -s http://127.0.0.1:8000/api/health
systemctl status personal-downloader-api.service --no-pager
systemctl status qbittorrent-nox.service --no-pager || systemctl status qbittorrent.service --no-pager
sudo nginx -t
```

Confirm current storage:

```bash
df -h
lsblk
sudo du -sh /home/ubuntu/personal-cloud-downloader 2>/dev/null
sudo du -sh /srv/personal-cloud/downloads 2>/dev/null
```

Do not delete anything in this phase.

### Phase 1, create app-only backup from current VM

Create a local app-only tarball excluding video folders.

Example command:

```bash
sudo mkdir -p /tmp/cloudbox-backup-root
sudo cp -a /home/ubuntu/personal-cloud-downloader /tmp/cloudbox-backup-root/ 2>/dev/null || true
sudo mkdir -p /tmp/cloudbox-backup-root/home-ubuntu-config
sudo cp -a /home/ubuntu/.config/cloudbox /tmp/cloudbox-backup-root/home-ubuntu-config/ 2>/dev/null || true
sudo mkdir -p /tmp/cloudbox-backup-root/etc-systemd-system
sudo cp -a /etc/systemd/system/personal-downloader-api.service /tmp/cloudbox-backup-root/etc-systemd-system/ 2>/dev/null || true
sudo cp -a /etc/systemd/system/qbittorrent*.service /tmp/cloudbox-backup-root/etc-systemd-system/ 2>/dev/null || true
sudo mkdir -p /tmp/cloudbox-backup-root/etc-nginx
sudo cp -a /etc/nginx/sites-available /tmp/cloudbox-backup-root/etc-nginx/ 2>/dev/null || true
sudo cp -a /etc/nginx/sites-enabled /tmp/cloudbox-backup-root/etc-nginx/ 2>/dev/null || true
sudo mkdir -p /tmp/cloudbox-backup-root/qbittorrent
sudo cp -a /home/ubuntu/.config/qBittorrent /tmp/cloudbox-backup-root/qbittorrent/ 2>/dev/null || true
sudo cp -a /home/ubuntu/.local/share/qBittorrent /tmp/cloudbox-backup-root/qbittorrent/ 2>/dev/null || true
sudo mkdir -p /tmp/cloudbox-backup-root/var-lib
sudo cp -a /var/lib/cloudbox /tmp/cloudbox-backup-root/var-lib/ 2>/dev/null || true
sudo dpkg --get-selections > /tmp/cloudbox-backup-root/cloudbox-installed-packages.txt
sudo systemctl list-unit-files > /tmp/cloudbox-backup-root/cloudbox-systemd-units.txt
cd /tmp
sudo tar -czf cloudbox-app-backup-$(date +%Y%m%d-%H%M).tar.gz cloudbox-backup-root
ls -lh /tmp/cloudbox-app-backup-*.tar.gz
```

Important:

```text
Do not include /srv/personal-cloud/downloads in this app-only backup.
```

Upload this backup to OCI Object Storage or download it to the PC before deleting the old VM.

### Phase 2, create new VM with 50GB boot volume

Target:

```text
New VM boot volume: 50GB
Do not create the 100GB block volume yet.
```

Storage math during this phase:

```text
Old boot 100GB + new boot 50GB = 150GB total
```

This should stay inside the 200GB Always Free Block Volume limit.

Set up new VM basics:

```text
Ubuntu 24.04
Tailscale
UFW rules for tailscale0 only
Python/FastAPI dependencies
qBittorrent-nox
Nginx
ffmpeg / ffprobe
vnstat
```

Security rule:

```text
Do not expose qBittorrent, Nginx streaming, or FastAPI publicly.
Keep access through Tailscale.
```

### Phase 3, restore app-only backup to new VM

Restore app code and configs:

```text
/home/ubuntu/personal-cloud-downloader
/home/ubuntu/.config/cloudbox
/etc/systemd/system/personal-downloader-api.service
/etc/systemd/system/qbittorrent*.service
/etc/nginx/sites-available
/etc/nginx/sites-enabled
/home/ubuntu/.config/qBittorrent
/home/ubuntu/.local/share/qBittorrent
/var/lib/cloudbox
```

Create temporary runtime folder on the new VM boot volume only for testing:

```bash
sudo mkdir -p /srv/personal-cloud/downloads/complete
sudo mkdir -p /srv/personal-cloud/downloads/incomplete
sudo chown -R ubuntu:ubuntu /srv/personal-cloud
```

Do not download large videos during this temporary test.

Reload services:

```bash
sudo systemctl daemon-reload
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl restart personal-downloader-api.service
sudo systemctl restart qbittorrent-nox.service || sudo systemctl restart qbittorrent.service
```

### Phase 4, verify new VM before deleting old VM

Minimum checks:

```bash
curl -s http://127.0.0.1:8000/api/health
curl -s http://127.0.0.1:8000/api/completed-files | head -c 300
sudo nginx -t
systemctl is-active personal-downloader-api.service
```

From PC/iPhone through Tailscale, verify:

```text
CloudBox web app opens
FastAPI /api/health works
qBittorrent Web UI opens
Nginx /files/ opens
subtitle endpoint exists
thumbnail logic does not crash completed-files
```

Do not delete the old VM until these checks pass.

### Phase 5, delete old 100GB boot volume after new VM is verified

Only after the new 50GB VM is proven working:

```text
Stop old VM.
Confirm no needed app data remains only on old VM.
Confirm app-only backup exists outside old VM.
Delete old instance and old 100GB boot volume.
```

Storage math after deletion:

```text
New boot 50GB only = 50GB total
```

### Phase 6, create and attach 100GB block volume

Create a new OCI block volume:

```text
Size: 100GB
Purpose: CloudBox data disk
Mount target: /srv/personal-cloud
```

Attach it to the new VM.

On the new VM, identify the disk:

```bash
lsblk
```

Create filesystem only if this is a new empty volume:

```bash
sudo mkfs.ext4 /dev/REPLACE_WITH_NEW_DEVICE
```

Mount it:

```bash
sudo mkdir -p /srv/personal-cloud
sudo mount /dev/REPLACE_WITH_NEW_DEVICE /srv/personal-cloud
sudo mkdir -p /srv/personal-cloud/downloads/complete
sudo mkdir -p /srv/personal-cloud/downloads/incomplete
sudo chown -R ubuntu:ubuntu /srv/personal-cloud
```

Add to `/etc/fstab` using UUID:

```bash
sudo blkid
```

Example fstab style:

```text
UUID=REPLACE_WITH_UUID /srv/personal-cloud ext4 defaults,nofail 0 2
```

Verify mount:

```bash
df -h /srv/personal-cloud
lsblk
```

Final storage math:

```text
50GB boot + 100GB block volume = 150GB total
```

### Phase 7, point qBittorrent and Nginx to mounted volume

qBittorrent paths should be:

```text
Completed: /srv/personal-cloud/downloads/complete
Incomplete: /srv/personal-cloud/downloads/incomplete
```

Nginx file serving should point to:

```text
/srv/personal-cloud/downloads/complete
```

Restart and verify:

```bash
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl restart qbittorrent-nox.service || sudo systemctl restart qbittorrent.service
sudo systemctl restart personal-downloader-api.service
curl -s http://127.0.0.1:8000/api/health
curl -s http://127.0.0.1:8000/api/completed-files | head -c 300
```

---

## 9. Delete Behavior After Migration

When CloudBox deletes a torrent/video package, it should delete these from `/srv/personal-cloud`:

```text
video file/folder
generated .srt / .vtt subtitle files
generated .srt.bak / .vtt.bak files
generated thumbnail file
future timeline thumbnail cache
empty leftover folders
```

It should also delete small app metadata from the app database if present:

```text
resume position
watched percent
watched badge
audio/subtitle preference
fit/cover preference
```

Recommended future database path:

```text
/var/lib/cloudbox/cloudbox.db
```

This database should be included in app-only backups.

---

## 10. Disaster Recovery Model After Migration

If the VM breaks but the 100GB block volume survives:

```text
1. Create new 50GB VM.
2. Attach existing 100GB block volume.
3. Mount it again at /srv/personal-cloud.
4. Restore latest app-only backup.
5. Reinstall required packages.
6. Restore services/configs.
7. Restart Nginx, qBittorrent, and FastAPI.
8. CloudBox returns with app/settings restored and old data disk available.
```

If the block volume itself is deleted or corrupted:

```text
Video/runtime data may be lost.
App can still be restored from app-only backup.
```

This is accepted because the project decision is:

```text
Do not back up video files.
Protect app brain only.
Use detachable block volume for best-effort video/data survival.
```

---

## 11. Must Not Do

```text
Do not create old 100GB boot + new 50GB boot + new 100GB block volume at the same time.
Do not delete the old VM before the app-only backup exists outside the old VM.
Do not delete the old VM before the new 50GB VM passes basic health checks.
Do not expose qBittorrent, Nginx, or FastAPI publicly.
Do not commit TMDB key, qB password, SSH keys, or secret env values.
Do not back up video files to Object Storage.
Do not run git pull inside /home/ubuntu/personal-cloud-downloader on Oracle because that folder is not a Git repo.
Do not format an existing block volume unless you are certain it is empty and disposable.
```

---

## 12. Success Criteria

Migration is successful only when:

```text
Oracle Block Volume total is at or below 150GB final target.
New VM boot volume is 50GB.
Separate 100GB block volume is mounted at /srv/personal-cloud.
Tailscale SSH works.
UFW allows private access only through tailscale0.
qBittorrent opens privately through Tailscale.
Nginx /files/ opens privately through Tailscale.
FastAPI /api/health returns OK.
CloudBox /app opens.
/api/completed-files works.
Subtitle extraction endpoint is present.
Thumbnail generation does not crash /api/completed-files.
Network dashboard endpoint works if vnstat is installed.
App-only backup exists outside the VM.
Old 100GB boot volume is deleted after migration.
Final storage total is 50GB + 100GB = 150GB.
```

---

## 13. Short Decision Summary

Use this as the locked decision:

```text
CloudBox storage target:
50GB boot volume for OS/app/config.
100GB separate OCI block volume mounted at /srv/personal-cloud for downloads, generated subtitles, thumbnails, and temporary runtime video data.
App-only Object Storage backup excludes video files.
Stay below Oracle Always Free 200GB total Block Volume limit.
Do not create the 100GB data disk until the old 100GB boot volume is deleted, unless total storage is confirmed safe in OCI Console.
```
