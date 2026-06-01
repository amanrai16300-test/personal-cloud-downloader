# Setup

Use this for a private server only. Download only files you have legal rights to download or distribute.

Current practical small-storage path: AWS EC2 Free Tier in Tokyo. Follow `docs/AWS_EC2_FREE_TIER_SETUP.md` first.

The Oracle plan remains available in `docs/PERSONAL_CLOUD_DOWNLOADER_PLAN.md`, but AWS EC2 Free Tier is the active small-storage setup path.

## 1. Prepare Server

Use Ubuntu on your private server.

Install base packages:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y python3 python3-venv python3-pip nginx qbittorrent-nox ufw curl
```

Create folders:

```bash
sudo mkdir -p /srv/torrents/downloads /srv/torrents/incomplete
```

## 2. Configure qBittorrent

Run `qbittorrent-nox` as a private service. Configure:

- Web UI on `127.0.0.1:8080` or Tailscale-only interface
- Strong Web UI password
- Default save path: `/srv/torrents/downloads`
- Incomplete path: `/srv/torrents/incomplete`
- Start torrents paused: enabled

## 3. Configure Backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Edit `backend/.env`:

```env
QB_BASE_URL=http://127.0.0.1:8080
QB_USERNAME=admin
QB_PASSWORD=CHANGE_THIS_PASSWORD
DOWNLOAD_DIR=/srv/torrents/downloads
PUBLIC_FILE_BASE_URL=http://TAILSCALE_SERVER_IP:8090/files
APP_API_KEY=CHANGE_THIS_RANDOM_SECRET
```

Run backend:

```bash
uvicorn main:app --host 127.0.0.1 --port 8000
```

## 4. Configure Frontend

Open `frontend/index.html`.

Set:

- API base URL: backend URL
- API key: `APP_API_KEY` from `backend/.env`

## 5. Serve Completed Files

Configure Nginx to serve `/srv/torrents/downloads` on a Tailscale-only port, for example `8090`.

Do not expose this port publicly.
