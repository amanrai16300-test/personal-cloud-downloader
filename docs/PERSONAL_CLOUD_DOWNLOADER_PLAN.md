# Personal Cloud Downloader Project Plan

Created: 2026-05-29  
Owner: Aman  
Project type: Private personal cloud downloader and streamer  
Main idea: iPhone browser controls a private cloud server. The cloud server downloads legal torrent files, stores them, and lets you download or stream completed files.

---

## 0. Very Important Legal and Safety Rule

This project must be used only for files you have the legal right to download or distribute.

Good legal test examples:
- Linux ISO torrents
- Public-domain media
- Your own files
- Open-source project releases
- Legal educational datasets

Do not use this project for copyrighted movies, shows, music, games, paid courses, or any content you do not have rights to download.

This plan is written for a private, legal, personal tool.

---

# 1. What You Are Building

You are building a private mini Seedr-style tool.

Simple flow:

```text
iPhone Safari
   ↓
Private web page or qBittorrent Web UI
   ↓
Oracle Cloud free Ubuntu server
   ↓
qBittorrent-nox downloads the selected legal file
   ↓
File is saved on cloud disk
   ↓
You stream/download it through VLC, Infuse, Safari, or browser
```

Important idea:

```text
Your iPhone is only the remote control.
The cloud server does the actual downloading and storing.
```

---

# 2. Best Free Cloud Choice

Recommended provider:

```text
Oracle Cloud Always Free
```

Why:
- Good free compute compared with other providers.
- Always Free Arm Ampere A1 compute can be enough for a personal server.
- Always Free block volume gives up to 200GB total block storage, including boot volume.
- Ubuntu is supported.
- Good for private projects when configured carefully.

Recommended starting configuration:

| Item | Recommended |
|---|---|
| Cloud provider | Oracle Cloud |
| Instance shape | VM.Standard.A1.Flex |
| CPU | 1 OCPU first |
| RAM | 6GB first |
| OS | Ubuntu 22.04 or 24.04 |
| Boot volume | 150GB to 180GB |
| Access | SSH + Tailscale |
| Public ports | SSH only at first |
| qBittorrent access | Tailscale only |
| File streaming | Tailscale only |

Important Oracle notes:
- Always Free storage is total combined block volume and boot volume.
- Boot volume counts inside the 200GB limit.
- If your region has no free Arm capacity, you may see an out-of-capacity error.
- Do not accidentally create paid resources.
- Set a budget/alert if Oracle account allows it.

---

# 3. Main Components

## 3.1 Oracle Cloud Ubuntu Server

This is the machine that runs everything.

It will run:
- qBittorrent-nox
- Tailscale
- Nginx or Caddy
- Optional FastAPI backend later
- Optional custom frontend later

## 3.2 qBittorrent-nox

This is the torrent engine.

It handles:
- Magnet link
- Metadata fetching
- File list
- Selecting only one file
- Downloading pieces
- Storing completed files

You do not code the torrent engine yourself.

## 3.3 Tailscale

This makes your server private.

Without Tailscale:

```text
Your server may be visible on the public internet.
```

With Tailscale:

```text
Only your iPhone and your server can talk privately.
```

## 3.4 Nginx or Caddy

This serves completed files to your iPhone.

Example final file link:

```text
http://100.x.x.x:8090/files/example.mp4
```

You can paste this into VLC:

```text
VLC → Network → Open Network Stream → paste link
```

## 3.5 Optional Custom App

Later, you can create your own clean page.

Frontend:
- Vue/Vite or simple HTML + JS

Backend:
- Python FastAPI

The custom app will control qBittorrent through its Web API.

---

# 4. Build Strategy

Do not build the custom app first.

Build in this order:

```text
Phase 1: Cloud server
Phase 2: qBittorrent Web UI
Phase 3: Tailscale private access
Phase 4: Nginx file streaming
Phase 5: Cleanup and safety
Phase 6: Custom FastAPI backend
Phase 7: Custom mobile frontend
```

Why this order?

Because qBittorrent Web UI already does most of what you need. First make the system work manually. Then build your own page on top.

---

# 5. Phase 1: Create Oracle Cloud Server

## 5.1 Create Oracle Cloud Account

Create an Oracle Cloud Free Tier account.

Important:
- Use your real region carefully.
- Prefer Japan East Tokyo or nearby region if available.
- Free capacity may not always be available.
- Avoid clicking paid shapes or paid storage options.

## 5.2 Create VM Instance

Go to:

```text
Oracle Cloud Console
→ Compute
→ Instances
→ Create Instance
```

Choose:

```text
Image: Ubuntu 22.04 or Ubuntu 24.04
Shape: VM.Standard.A1.Flex
OCPU: 1
RAM: 6GB
Boot volume: 150GB to 180GB
Public IP: Yes, only for SSH setup
SSH key: Generate or upload your SSH key
```

Do not open qBittorrent ports publicly.

At first, only SSH should be open.

## 5.3 SSH Into Server

From your computer:

```bash
ssh ubuntu@YOUR_ORACLE_PUBLIC_IP
```

If your key file is needed:

```bash
ssh -i /path/to/private-key ubuntu@YOUR_ORACLE_PUBLIC_IP
```

## 5.4 Update Server

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl wget git unzip htop ufw nginx qbittorrent-nox
```

Check disk:

```bash
df -h
```

Check OS:

```bash
lsb_release -a
```

---

# 6. Phase 2: Prepare Download Folders

Create folders:

```bash
sudo mkdir -p /srv/torrents/downloads
sudo mkdir -p /srv/torrents/incomplete
sudo mkdir -p /srv/torrents/watch
```

Create qBittorrent service user:

```bash
sudo adduser --system --group --home /var/lib/qbittorrent qbtuser
```

Give ownership:

```bash
sudo chown -R qbtuser:qbtuser /srv/torrents
sudo chown -R qbtuser:qbtuser /var/lib/qbittorrent
```

Set folder permissions:

```bash
sudo chmod -R 750 /srv/torrents
```

Allow Nginx to read completed files later:

```bash
sudo usermod -aG qbtuser www-data
```

---

# 7. Phase 3: Initialize qBittorrent-nox

Run qBittorrent once manually:

```bash
sudo -u qbtuser -H qbittorrent-nox
```

It may show:
- Web UI address
- Admin username
- Temporary password or default password depending on version

Default username is usually:

```text
admin
```

Depending on version, password may be:
- shown as a temporary password in console/log
- or older default may be `adminadmin`

After you see it started, stop it:

```text
Ctrl + C
```

Important:
- Change the Web UI password after first login.
- Do not keep default password.

---

# 8. Phase 4: Run qBittorrent as a Background Service

Create systemd service:

```bash
sudo nano /etc/systemd/system/qbittorrent-nox.service
```

Paste:

```ini
[Unit]
Description=qBittorrent-nox service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=qbtuser
Group=qbtuser
UMask=0027
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable qbittorrent-nox
sudo systemctl start qbittorrent-nox
sudo systemctl status qbittorrent-nox
```

Check logs:

```bash
journalctl -u qbittorrent-nox -n 100 --no-pager
```

If password is temporary, logs may show it.

---

# 9. Phase 5: Install Tailscale

Install Tailscale:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Start login:

```bash
sudo tailscale up
```

Open the login link shown in terminal.

Install Tailscale on iPhone:
- Open App Store
- Install Tailscale
- Login with same account

Check server Tailscale IP:

```bash
tailscale ip -4
```

Example:

```text
100.80.20.10
```

Now your iPhone can privately access the server using this Tailscale IP.

---

# 10. Phase 6: Firewall Setup

Use UFW.

Allow SSH first:

```bash
sudo ufw allow OpenSSH
```

Allow qBittorrent Web UI only through Tailscale:

```bash
sudo ufw allow in on tailscale0 to any port 8080 proto tcp
```

Allow future file streaming only through Tailscale:

```bash
sudo ufw allow in on tailscale0 to any port 8090 proto tcp
```

Enable firewall:

```bash
sudo ufw enable
```

Check:

```bash
sudo ufw status verbose
```

Important:
- Do not open port 8080 publicly in Oracle Security List.
- Do not open port 8090 publicly.
- Use Tailscale access only.

---

# 11. Phase 7: Open qBittorrent From iPhone

On iPhone:
1. Open Tailscale app.
2. Make sure it is connected.
3. Open Safari.
4. Open:

```text
http://TAILSCALE_SERVER_IP:8080
```

Example:

```text
http://100.80.20.10:8080
```

Login:
- Username: `admin`
- Password: from console/log or your changed password

Immediately change password:

```text
Tools → Options → Web UI → Password
```

---

# 12. Phase 8: Recommended qBittorrent Settings

Inside qBittorrent Web UI:

Go to:

```text
Tools → Options
```

Recommended settings:

| Setting | Value |
|---|---|
| Default save path | `/srv/torrents/downloads` |
| Incomplete torrents path | `/srv/torrents/incomplete` |
| Start torrents paused | ON |
| Max active downloads | 1 or 2 |
| Max active uploads | 0 or 1 |
| Max active torrents | 2 |
| Web UI username/password | Strong password |
| Bypass authentication | OFF |
| CSRF protection | ON |
| Clickjacking protection | ON |
| Host header validation | ON |
| Alternative speed limits | Optional |
| Stop seeding after ratio | Optional, low for private personal use |
| Stop seeding after time | Optional |

Important for one-file download:

```text
Start torrents paused = ON
```

This lets you paste a magnet, wait for metadata, choose one file, then start.

---

# 13. Daily Use Flow With qBittorrent Web UI

Use this only for legal files.

## 13.1 Add Magnet

1. Open qBittorrent Web UI on iPhone.
2. Click add torrent/magnet.
3. Paste legal magnet link.
4. Add it paused if possible.

## 13.2 Wait for Metadata

A magnet link first needs metadata.

Wait until qBittorrent shows:
- torrent name
- file list
- total size

If it shows only hash/no files, metadata is not ready yet.

## 13.3 Select Only One File

1. Open torrent contents/files.
2. Untick all files or set unwanted files to “do not download.”
3. Tick only the file you want.
4. Resume/start the torrent.

## 13.4 Download on Cloud

The file downloads to:

```text
/srv/torrents/downloads/
```

Not your iPhone.

## 13.5 Stream or Download

After complete:
- Download from server link
- Or stream using VLC/Infuse

---

# 14. Phase 9: Serve Completed Files With Nginx

qBittorrent downloads files, but Nginx gives clean streaming links.

Create Nginx config:

```bash
sudo nano /etc/nginx/sites-available/torrent-files
```

Paste:

```nginx
server {
    listen 8090;
    server_name _;

    client_max_body_size 0;

    location /files/ {
        alias /srv/torrents/downloads/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        add_header X-Content-Type-Options nosniff;

        types {
            video/mp4 mp4;
            video/x-matroska mkv;
            video/webm webm;
            application/octet-stream bin exe rar zip 7z;
        }

        default_type application/octet-stream;
    }
}
```

Enable site:

```bash
sudo ln -s /etc/nginx/sites-available/torrent-files /etc/nginx/sites-enabled/torrent-files
sudo nginx -t
sudo systemctl reload nginx
```

Test from server:

```bash
curl -I http://127.0.0.1:8090/files/
```

From iPhone, open:

```text
http://TAILSCALE_SERVER_IP:8090/files/
```

Example:

```text
http://100.80.20.10:8090/files/
```

If you see a file list, it works.

---

# 15. Stream in VLC on iPhone

1. Open VLC on iPhone.
2. Go to:

```text
Network → Open Network Stream
```

3. Paste file URL:

```text
http://TAILSCALE_SERVER_IP:8090/files/FILENAME.mp4
```

Example:

```text
http://100.80.20.10:8090/files/example.mp4
```

4. Tap play.

Notes:
- MP4 usually streams smoothly.
- MKV may work in VLC.
- Safari may not play every video format.
- VLC is better for many formats.
- Nginx supports range requests by default, which helps video seeking.

---

# 16. Phase 10: Auto Cleanup Script

You must prevent disk full problems.

Create cleanup script:

```bash
sudo nano /usr/local/bin/cleanup-torrents.sh
```

Paste:

```bash
#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_DIR="/srv/torrents/downloads"
INCOMPLETE_DIR="/srv/torrents/incomplete"
DAYS_TO_KEEP_COMPLETED=3
DAYS_TO_KEEP_INCOMPLETE=2

echo "Cleaning completed files older than ${DAYS_TO_KEEP_COMPLETED} days..."
find "$DOWNLOAD_DIR" -type f -mtime +"$DAYS_TO_KEEP_COMPLETED" -print -delete

echo "Cleaning empty completed directories..."
find "$DOWNLOAD_DIR" -type d -empty -print -delete

echo "Cleaning incomplete files older than ${DAYS_TO_KEEP_INCOMPLETE} days..."
find "$INCOMPLETE_DIR" -type f -mtime +"$DAYS_TO_KEEP_INCOMPLETE" -print -delete

echo "Cleaning empty incomplete directories..."
find "$INCOMPLETE_DIR" -type d -empty -print -delete

echo "Done."
```

Make executable:

```bash
sudo chmod +x /usr/local/bin/cleanup-torrents.sh
```

Test manually:

```bash
sudo /usr/local/bin/cleanup-torrents.sh
```

Create cron job:

```bash
sudo crontab -e
```

Add:

```cron
0 4 * * * /usr/local/bin/cleanup-torrents.sh >> /var/log/cleanup-torrents.log 2>&1
```

This runs every day at 4 AM server time.

---

# 17. Phase 11: Optional Custom App Overview

After qBittorrent Web UI works, build your own clean personal dashboard.

Your custom app:

```text
iPhone page
   ↓
FastAPI backend
   ↓
qBittorrent Web API
   ↓
qBittorrent engine
   ↓
Nginx file streaming
```

You still do not build the torrent engine.

Your app only controls qBittorrent.

---

# 18. Custom App Folder Structure

Recommended project:

```text
personal-cloud-downloader/
├── README.md
├── backend/
│   ├── main.py
│   ├── qb_client.py
│   ├── settings.py
│   ├── requirements.txt
│   └── .env.example
├── frontend/
│   ├── index.html
│   ├── app.js
│   └── style.css
├── scripts/
│   ├── cleanup-torrents.sh
│   └── install-server.sh
└── docs/
    ├── SETUP.md
    ├── SECURITY.md
    └── USAGE.md
```

---

# 19. Backend API Design

Use FastAPI.

Required endpoints:

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | GET | Check backend is alive |
| `/api/add-magnet` | POST | Add magnet to qBittorrent paused |
| `/api/torrents` | GET | Show torrent list and progress |
| `/api/torrents/{hash}/files` | GET | Show file list inside torrent |
| `/api/torrents/{hash}/select-file` | POST | Set all files to skip, selected file to normal |
| `/api/torrents/{hash}/start` | POST | Start/resume torrent |
| `/api/torrents/{hash}/pause` | POST | Pause torrent |
| `/api/torrents/{hash}` | DELETE | Delete torrent from qBittorrent |
| `/api/completed-files` | GET | Show completed downloadable/streamable files |

---

# 20. Backend Environment Variables

Create:

```text
backend/.env
```

Example:

```env
QB_BASE_URL=http://127.0.0.1:8080
QB_USERNAME=admin
QB_PASSWORD=CHANGE_THIS_PASSWORD
DOWNLOAD_DIR=/srv/torrents/downloads
PUBLIC_FILE_BASE_URL=http://TAILSCALE_SERVER_IP:8090/files
APP_API_KEY=CHANGE_THIS_RANDOM_SECRET
MAX_MAGNET_LENGTH=12000
MAX_SELECTED_FILE_SIZE_GB=20
```

Important:
- Never commit `.env`.
- Commit only `.env.example`.

---

# 21. Backend Requirements

Create:

```text
backend/requirements.txt
```

Content:

```txt
fastapi
uvicorn[standard]
requests
python-dotenv
pydantic
```

Install:

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

# 22. Example Backend qBittorrent Client

File:

```text
backend/qb_client.py
```

Starter code:

```python
import os
from typing import Any

import requests
from dotenv import load_dotenv

load_dotenv()

QB_BASE_URL = os.getenv("QB_BASE_URL", "http://127.0.0.1:8080")
QB_USERNAME = os.getenv("QB_USERNAME", "admin")
QB_PASSWORD = os.getenv("QB_PASSWORD", "")


class QBittorrentClient:
    def __init__(self) -> None:
        self.session = requests.Session()
        self.base_url = QB_BASE_URL.rstrip("/")

    def login(self) -> None:
        response = self.session.post(
            f"{self.base_url}/api/v2/auth/login",
            data={
                "username": QB_USERNAME,
                "password": QB_PASSWORD,
            },
            timeout=10,
        )

        if response.status_code != 200 or response.text.strip().lower() == "fails.":
            raise RuntimeError("qBittorrent login failed. Check username/password.")

    def add_magnet_paused(self, magnet: str) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/add",
            data={
                "urls": magnet,
                "paused": "true",
            },
            timeout=20,
        )
        response.raise_for_status()

    def list_torrents(self) -> list[dict[str, Any]]:
        self.login()
        response = self.session.get(
            f"{self.base_url}/api/v2/torrents/info",
            timeout=10,
        )
        response.raise_for_status()
        return response.json()

    def get_files(self, torrent_hash: str) -> list[dict[str, Any]]:
        self.login()
        response = self.session.get(
            f"{self.base_url}/api/v2/torrents/files",
            params={"hash": torrent_hash},
            timeout=10,
        )
        response.raise_for_status()
        return response.json()

    def set_file_priority(self, torrent_hash: str, file_ids: list[int], priority: int) -> None:
        self.login()
        ids = "|".join(str(file_id) for file_id in file_ids)
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/filePrio",
            data={
                "hash": torrent_hash,
                "id": ids,
                "priority": priority,
            },
            timeout=10,
        )
        response.raise_for_status()

    def select_only_one_file(self, torrent_hash: str, selected_file_id: int) -> None:
        files = self.get_files(torrent_hash)
        all_ids = [int(file["index"]) for file in files]

        if selected_file_id not in all_ids:
            raise ValueError("Selected file id does not exist in torrent.")

        # 0 = Do not download
        self.set_file_priority(torrent_hash, all_ids, 0)

        # 1 = Normal priority
        self.set_file_priority(torrent_hash, [selected_file_id], 1)

    def resume(self, torrent_hash: str) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/resume",
            data={"hashes": torrent_hash},
            timeout=10,
        )
        response.raise_for_status()

    def pause(self, torrent_hash: str) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/pause",
            data={"hashes": torrent_hash},
            timeout=10,
        )
        response.raise_for_status()

    def delete(self, torrent_hash: str, delete_files: bool = False) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/delete",
            data={
                "hashes": torrent_hash,
                "deleteFiles": "true" if delete_files else "false",
            },
            timeout=10,
        )
        response.raise_for_status()
```

---

# 23. Example FastAPI Backend

File:

```text
backend/main.py
```

Starter code:

```python
import os
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

from qb_client import QBittorrentClient

load_dotenv()

APP_API_KEY = os.getenv("APP_API_KEY", "")
DOWNLOAD_DIR = Path(os.getenv("DOWNLOAD_DIR", "/srv/torrents/downloads"))
PUBLIC_FILE_BASE_URL = os.getenv("PUBLIC_FILE_BASE_URL", "")

app = FastAPI(title="Personal Cloud Downloader")
qb = QBittorrentClient()


class AddMagnetRequest(BaseModel):
    magnet: str


class SelectFileRequest(BaseModel):
    file_id: int


def require_api_key(x_api_key: str | None) -> None:
    if not APP_API_KEY:
        raise HTTPException(status_code=500, detail="APP_API_KEY is not configured.")

    if x_api_key != APP_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key.")


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/add-magnet")
def add_magnet(payload: AddMagnetRequest, x_api_key: str | None = Header(default=None)) -> dict[str, str]:
    require_api_key(x_api_key)

    if not payload.magnet.startswith("magnet:?"):
        raise HTTPException(status_code=400, detail="Only magnet links are accepted.")

    if len(payload.magnet) > int(os.getenv("MAX_MAGNET_LENGTH", "12000")):
        raise HTTPException(status_code=400, detail="Magnet link is too long.")

    qb.add_magnet_paused(payload.magnet)
    return {"status": "added_paused"}


@app.get("/api/torrents")
def list_torrents(x_api_key: str | None = Header(default=None)) -> list[dict[str, Any]]:
    require_api_key(x_api_key)
    return qb.list_torrents()


@app.get("/api/torrents/{torrent_hash}/files")
def get_torrent_files(torrent_hash: str, x_api_key: str | None = Header(default=None)) -> list[dict[str, Any]]:
    require_api_key(x_api_key)
    return qb.get_files(torrent_hash)


@app.post("/api/torrents/{torrent_hash}/select-file")
def select_file(
    torrent_hash: str,
    payload: SelectFileRequest,
    x_api_key: str | None = Header(default=None),
) -> dict[str, str]:
    require_api_key(x_api_key)
    qb.select_only_one_file(torrent_hash, payload.file_id)
    return {"status": "selected"}


@app.post("/api/torrents/{torrent_hash}/start")
def start_torrent(torrent_hash: str, x_api_key: str | None = Header(default=None)) -> dict[str, str]:
    require_api_key(x_api_key)
    qb.resume(torrent_hash)
    return {"status": "started"}


@app.post("/api/torrents/{torrent_hash}/pause")
def pause_torrent(torrent_hash: str, x_api_key: str | None = Header(default=None)) -> dict[str, str]:
    require_api_key(x_api_key)
    qb.pause(torrent_hash)
    return {"status": "paused"}


@app.delete("/api/torrents/{torrent_hash}")
def delete_torrent(
    torrent_hash: str,
    delete_files: bool = False,
    x_api_key: str | None = Header(default=None),
) -> dict[str, str]:
    require_api_key(x_api_key)
    qb.delete(torrent_hash, delete_files=delete_files)
    return {"status": "deleted"}


@app.get("/api/completed-files")
def completed_files(x_api_key: str | None = Header(default=None)) -> list[dict[str, str]]:
    require_api_key(x_api_key)

    if not DOWNLOAD_DIR.exists():
        return []

    results = []
    for file_path in DOWNLOAD_DIR.rglob("*"):
        if file_path.is_file():
            relative_path = file_path.relative_to(DOWNLOAD_DIR).as_posix()
            results.append(
                {
                    "name": relative_path,
                    "url": f"{PUBLIC_FILE_BASE_URL}/{relative_path}",
                }
            )

    return results
```

Run backend:

```bash
cd backend
source .venv/bin/activate
uvicorn main:app --host 127.0.0.1 --port 8000
```

Test health:

```bash
curl http://127.0.0.1:8000/api/health
```

---

# 24. Custom Backend systemd Service

Create service:

```bash
sudo nano /etc/systemd/system/personal-downloader-api.service
```

Paste:

```ini
[Unit]
Description=Personal Cloud Downloader FastAPI backend
After=network-online.target qbittorrent-nox.service
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/personal-cloud-downloader/backend
EnvironmentFile=/home/ubuntu/personal-cloud-downloader/backend/.env
ExecStart=/home/ubuntu/personal-cloud-downloader/backend/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable personal-downloader-api
sudo systemctl start personal-downloader-api
sudo systemctl status personal-downloader-api
```

Logs:

```bash
journalctl -u personal-downloader-api -n 100 --no-pager
```

---

# 25. Custom Frontend MVP

For first frontend, use simple HTML + JS.

File:

```text
frontend/index.html
```

Basic idea:
- Input for magnet link
- API key input
- Add button
- Torrent list
- File list
- Select/start buttons
- Completed file links

You can host it with Nginx later.

Do not build a fancy UI first. Make it work first.

---

# 26. Custom App API Flow

## Add magnet

Frontend sends:

```http
POST /api/add-magnet
x-api-key: YOUR_SECRET
```

Body:

```json
{
  "magnet": "magnet:?..."
}
```

Backend sends to qBittorrent as paused.

## Get torrents

Frontend polls:

```http
GET /api/torrents
x-api-key: YOUR_SECRET
```

It gets:
- hash
- name
- progress
- state
- size
- download speed

## Get file list

Frontend calls:

```http
GET /api/torrents/{hash}/files
x-api-key: YOUR_SECRET
```

It shows:
- file name
- file size
- file id/index
- priority
- progress

## Select one file

Frontend sends:

```http
POST /api/torrents/{hash}/select-file
x-api-key: YOUR_SECRET
```

Body:

```json
{
  "file_id": 0
}
```

Backend:
- sets all files priority to 0
- sets selected file priority to 1

## Start download

Frontend sends:

```http
POST /api/torrents/{hash}/start
x-api-key: YOUR_SECRET
```

## Stream completed file

Frontend shows:

```text
http://TAILSCALE_SERVER_IP:8090/files/filename.mp4
```

You open it in VLC.

---

# 27. Security Rules

This is important.

## Must do

- Use Tailscale.
- Keep qBittorrent private.
- Keep Nginx file server private.
- Use strong qBittorrent password.
- Use API key for custom backend.
- Never expose port 8080 publicly.
- Never expose port 8090 publicly.
- Never expose FastAPI publicly without auth.
- Use firewall.
- Keep Oracle Security List strict.
- Use cleanup script.

## Avoid

- Public signups.
- Public file links.
- Public torrent download page.
- No-auth backend.
- Storing copyrighted content.
- Unlimited storage.
- Unlimited bandwidth.
- Running as root.

---

# 28. Oracle Cloud Security List Recommendation

In Oracle Cloud networking, keep inbound rules minimal.

Recommended inbound rules at first:

| Port | Source | Purpose |
|---|---|---|
| 22 | Your IP only if possible | SSH |
| 8080 | Do not open publicly | qBittorrent Web UI |
| 8090 | Do not open publicly | file streaming |
| 8000 | Do not open publicly | FastAPI backend |

After Tailscale works, you can even avoid using public SSH regularly and use Tailscale SSH if configured.

---

# 29. Testing Checklist

## Server setup

- [ ] Oracle VM created
- [ ] Ubuntu installed
- [ ] SSH works
- [ ] Disk size checked with `df -h`
- [ ] Firewall enabled
- [ ] Tailscale installed
- [ ] iPhone Tailscale connected

## qBittorrent

- [ ] qBittorrent-nox installed
- [ ] qBittorrent service starts
- [ ] qBittorrent Web UI opens through Tailscale
- [ ] Password changed
- [ ] Download path set to `/srv/torrents/downloads`
- [ ] Start paused enabled
- [ ] Legal test torrent added
- [ ] Metadata loads
- [ ] File list visible
- [ ] One file selection works
- [ ] File downloads to cloud server

## Streaming

- [ ] Nginx installed
- [ ] Nginx file server opens through Tailscale
- [ ] Completed files visible
- [ ] VLC can open network stream
- [ ] Safari can download file
- [ ] Large file seeking works in VLC

## Cleanup

- [ ] Cleanup script created
- [ ] Manual cleanup test works
- [ ] Cron job added
- [ ] Log file created

## Custom app later

- [ ] FastAPI health works
- [ ] qBittorrent API login works
- [ ] Add magnet endpoint works
- [ ] List torrents endpoint works
- [ ] List files endpoint works
- [ ] Select one file endpoint works
- [ ] Start endpoint works
- [ ] Completed files endpoint works
- [ ] Mobile frontend works

---

# 30. Troubleshooting

## Problem: Oracle says “out of host capacity”

Meaning:
- Free Arm server is not available in that availability domain.

Try:
- Different availability domain
- Smaller shape, 1 OCPU and 6GB RAM
- Different region if possible
- Try again later

## Problem: I cannot open qBittorrent from iPhone

Check:
- Tailscale connected on iPhone
- Tailscale running on server

```bash
sudo systemctl status tailscaled
tailscale status
tailscale ip -4
```

Check qBittorrent service:

```bash
sudo systemctl status qbittorrent-nox
journalctl -u qbittorrent-nox -n 100 --no-pager
```

Check firewall:

```bash
sudo ufw status verbose
```

## Problem: qBittorrent password not working

Check logs:

```bash
journalctl -u qbittorrent-nox -n 200 --no-pager
```

Some versions show a temporary password in logs.

## Problem: Magnet added but no files show

Possible reasons:
- Metadata not downloaded yet
- No peers
- Dead torrent
- DHT/tracker problem
- Network blocked

Wait a little and test with a known legal Linux ISO torrent.

## Problem: Disk is full

Check disk:

```bash
df -h
du -h --max-depth=1 /srv/torrents
```

Delete old files:

```bash
sudo /usr/local/bin/cleanup-torrents.sh
```

Or manually delete files you do not need.

## Problem: VLC cannot play

Try:
- Copy exact URL
- Encode spaces as `%20`
- Use VLC instead of Safari
- Check Nginx file list first
- Check file completed fully
- Try MP4 first
- Test with smaller legal video file

## Problem: Nginx says permission denied

Fix group:

```bash
sudo usermod -aG qbtuser www-data
sudo systemctl restart nginx
```

Check permissions:

```bash
namei -l /srv/torrents/downloads
```

---

# 31. First AI Coding Prompt for This Project

Use this when you ask Codex/Claude to create the backend skeleton.

```text
Start with the most related file to this task. Stop and ask before reading any other file.

Create ONLY the backend MVP for my private personal cloud downloader.

Goal:
Build a FastAPI backend that controls qBittorrent Web API on the same server.

Files to create:
- backend/main.py
- backend/qb_client.py
- backend/settings.py
- backend/requirements.txt
- backend/.env.example

Required endpoints:
- GET /api/health
- POST /api/add-magnet
- GET /api/torrents
- GET /api/torrents/{hash}/files
- POST /api/torrents/{hash}/select-file
- POST /api/torrents/{hash}/start
- POST /api/torrents/{hash}/pause
- DELETE /api/torrents/{hash}
- GET /api/completed-files

Requirements:
- Use qBittorrent Web API.
- Add magnet links paused.
- For file selection, set all torrent files to priority 0, then selected file to priority 1.
- Use APP_API_KEY header authentication with x-api-key.
- Read settings from .env.
- Do not build frontend yet.
- Do not add database yet.
- Do not deploy.
- Do not use Docker.
- Do not change unrelated files.
- Keep code simple and readable.
```

---

# 32. First Manual Setup Prompt for AI Help

Use this when asking AI to guide setup step by step.

```text
I am creating a private personal cloud downloader for legal files only.

Target setup:
Oracle Cloud Always Free Ubuntu server
qBittorrent-nox
Tailscale private access
Nginx file streaming
Later FastAPI backend

Please guide me step by step.
Start with Oracle Cloud VM setup only.
Do not jump ahead.
After each step, ask me to confirm before continuing.
Keep commands copy-paste friendly.
```

---

# 33. MVP Definition of Done

The first useful version is done when:

```text
From iPhone:
1. Open Tailscale.
2. Open qBittorrent Web UI.
3. Paste legal magnet link.
4. Wait for metadata.
5. Select one file only.
6. Start download.
7. Wait until complete.
8. Open file link through Nginx.
9. Play in VLC.
```

No custom coding is required for MVP.

Coding starts only after this manual system works.

---

# 34. Recommended Next Action

Start with this only:

```text
Create Oracle Cloud Always Free Ubuntu VM.
Use Ampere A1 Flex.
Use 1 OCPU and 6GB RAM.
Use 150GB to 180GB boot volume.
Open only SSH.
Do not install anything until SSH works.
```

After SSH works, continue with:
- server update
- qBittorrent-nox install
- Tailscale install
- qBittorrent Web UI test

---

# 35. Official References

Use official docs first:

- Oracle Always Free resources: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- Oracle Cloud Free Tier: https://www.oracle.com/cloud/free/
- qBittorrent official website: https://www.qbittorrent.org/
- qBittorrent nox Web UI/systemd guide: https://github.com/qbittorrent/qBittorrent/wiki/Running-qBittorrent-without-X-server-%28WebUI-only%2C-systemd-service-set-up%2C-Ubuntu-15.04-or-newer%29
- qBittorrent Web API: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-4.1%29
- Tailscale pricing: https://tailscale.com/pricing

---

# 36. Seedr-style Wrapper App Plan

## 36.1 Purpose

Build a private Seedr-style downloader UI on top of the current working setup.

qBittorrent should stay as the hidden backend engine. Normal use should happen through the custom app, not through the qBittorrent torrent-manager UI.

The app must be cloud-neutral:
- Current cloud: AWS EC2 Ubuntu server
- Future cloud: Oracle A1 Ubuntu server
- Same app code should work on both clouds
- Cloud-specific values should live in environment variables

Current working private services:

```text
qBittorrent Web UI: http://100.125.15.118:8080
Nginx file streaming: http://100.125.15.118:8090/files/
Completed downloads: /srv/personal-cloud/downloads/complete
Incomplete downloads: /srv/personal-cloud/downloads/incomplete
```

Private access must remain through Tailscale only. Do not expose ports `8000`, `8080`, or `8090` publicly.

## 36.2 User Flow

```text
1. Open private app page through Tailscale.
2. Paste magnet link or upload .torrent file.
3. Click Start Download.
4. App adds the torrent to qBittorrent through qBittorrent Web API.
5. App shows simple status only.
6. When download completes, app shows final files only.
7. User streams, downloads, copies VLC link, or deletes files.
```

Simple statuses only:
- Waiting
- Downloading
- Completed
- Failed

Hide torrent-manager details from normal users:
- Peers
- Seeds
- Ratio
- Trackers
- Pieces
- Queue

For each completed file, show:
- Stream
- Download
- Copy VLC link
- Delete

## 36.3 Auto-stop Seeding Requirement

After a torrent finishes downloading, the app must automatically stop seeding to reduce cloud outbound traffic and avoid unnecessary cost.

Implement this in two layers.

### qBittorrent Setting Layer

- Configure qBittorrent share-ratio or seeding limits so torrents pause after completion, or after the minimum allowed ratio/time.
- Preferred action: `Pause them`.
- Do not use `Remove them` as the preferred action because the app still needs access to completed files.

### App Backend Layer

- Backend checks torrent status and progress through qBittorrent Web API.
- When progress is `100%`, or state shows completed/uploading/stalled upload, immediately call qBittorrent Web API to pause that torrent.
- App then marks the item as `Completed`.
- App shows final files only.
- Do not delete files automatically at completion.
- Delete files only when the user clicks `Delete`.

## 36.4 Architecture

```text
User browser / iPhone / Windows
   ↓
Private Seedr-style app on port 8000
   ↓
FastAPI backend
   ↓
qBittorrent Web API on localhost or Tailscale/private address port 8080
   ↓
Download folders
   ↓
Nginx private file streaming on port 8090
```

Recommended backend connection:

```text
FastAPI → http://127.0.0.1:8080
```

Use Tailscale/private address only if localhost is not possible.

## 36.5 Recommended Stack

- Python FastAPI backend
- Simple HTML/CSS/JS UI first
- qBittorrent Web API client module
- File service module for completed files
- systemd service later
- Environment variables for all paths, URLs, credentials, and ports

## 36.6 Environment Variables

```env
APP_HOST=0.0.0.0
APP_PORT=8000
QB_URL=http://127.0.0.1:8080
QB_USERNAME=admin
QB_PASSWORD=CHANGE_ME
DOWNLOAD_COMPLETE_DIR=/srv/personal-cloud/downloads/complete
DOWNLOAD_INCOMPLETE_DIR=/srv/personal-cloud/downloads/incomplete
STREAM_BASE_URL=http://TAILSCALE_IP:8090/files
MAX_DOWNLOAD_GB=10
AUTO_PAUSE_ON_COMPLETE=true
DELETE_FILES_ONLY_ON_USER_ACTION=true
```

Rules:
- Do not commit real passwords.
- Do not hardcode AWS public IP or Oracle public IP.
- Use environment variables when moving from AWS to Oracle.

## 36.7 Development Phases

### Phase 1

Create FastAPI MVP that can:
- Connect to qBittorrent Web API
- Add magnet links
- Upload `.torrent` files
- Show simple torrent progress

### Phase 2

Build simple Seedr-style UI:
- Paste magnet link
- Upload `.torrent` file
- Start download
- Show only Waiting, Downloading, Completed, or Failed
- Do not show torrent-manager details

### Phase 3

When a download completes:
- Auto-pause the torrent to stop seeding
- Mark it as Completed
- Show final files from `/srv/personal-cloud/downloads/complete`

### Phase 4

Add completed-file actions:
- Stream
- Download
- Copy VLC link
- Delete

### Phase 5

Add systemd service for the app:
- Run app on port `8000`
- Keep access private through Tailscale only
- Do not expose app publicly

### Phase 6

Make setup portable to future Oracle A1:
- Change only environment variables
- Do not change app code
- Do not add cloud-specific code

## 36.8 Safety Rules

- Legal files only.
- Keep downloads under 10GB.
- Stop seeding after completion.
- Delete files quickly after use.
- Keep qBittorrent hidden from normal use.
- Keep qBittorrent, Nginx, and the new app private through Tailscale.
- Do not expose ports `8000`, `8080`, or `8090` publicly.
- Do not commit passwords, PEM files, SSH keys, API keys, or secrets.
- Do not hardcode AWS public IP or Oracle public IP.
- Do not add cloud-specific code.
- Do not change current AWS working setup while writing this plan.
- Do not change Oracle retry script while writing this plan.

---

# 37. Short Summary

You are not building a full cloud torrent company.

You are building this:

```text
Private iPhone-controlled cloud downloader
for legal files only
using Oracle Free VM + qBittorrent + Tailscale + Nginx
```

Fastest path:

```text
First make qBittorrent Web UI work.
Then add streaming.
Then add cleanup.
Then build custom FastAPI + frontend.
```
