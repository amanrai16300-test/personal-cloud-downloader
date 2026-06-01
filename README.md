# Personal Cloud Downloader

Private personal cloud downloader for legal files only.

This project is an MVP skeleton for:

- FastAPI backend controlling qBittorrent Web API
- Plain HTML/CSS/JS mobile-friendly frontend
- Tailscale-only private access
- Nginx-served completed files

Do not expose qBittorrent, FastAPI, or file-serving ports publicly.

## Project Layout

```text
backend/   FastAPI backend and qBittorrent client
frontend/  Simple browser UI
docs/      Setup, security, usage, and progress notes
scripts/   Server helper scripts
```

## Start Locally

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn main:app --host 127.0.0.1 --port 8000
```

Open `frontend/index.html` in a browser and set the API base URL to:

```text
http://127.0.0.1:8000
```

See `docs/SETUP.md`, `docs/SECURITY.md`, and `docs/USAGE.md`.

Current practical small-storage setup path: `docs/AWS_EC2_FREE_TIER_SETUP.md`.
The original Oracle plan remains in `docs/PERSONAL_CLOUD_DOWNLOADER_PLAN.md`.
