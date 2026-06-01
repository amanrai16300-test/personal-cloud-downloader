import asyncio
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from requests import RequestException

from qb_client import QBittorrentClient
from settings import settings

app = FastAPI(title="Personal Cloud Downloader")
qb = QBittorrentClient()
monitor_task: asyncio.Task[None] | None = None

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["content-type"],
)


class AddMagnetRequest(BaseModel):
    magnet: str


class SelectFileRequest(BaseModel):
    file_id: int


def run_qb_action(action: str, *args: Any, **kwargs: Any) -> Any:
    try:
        method = getattr(qb, action)
        return method(*args, **kwargs)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except (RuntimeError, RequestException) as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.on_event("startup")
async def start_auto_pause_monitor() -> None:
    global monitor_task
    if settings.auto_pause_on_complete:
        monitor_task = asyncio.create_task(auto_pause_monitor())


@app.on_event("shutdown")
async def stop_auto_pause_monitor() -> None:
    if monitor_task:
        monitor_task.cancel()


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/add-magnet")
def add_magnet(payload: AddMagnetRequest) -> dict[str, str]:
    if not payload.magnet.startswith("magnet:?"):
        raise HTTPException(status_code=400, detail="Only magnet links are accepted.")

    run_qb_action("add_magnet", payload.magnet)
    return {"status": "added"}


@app.get("/api/qbittorrent/test")
def test_qbittorrent() -> dict[str, str]:
    run_qb_action("test_connection")
    return {"status": "ok"}


@app.get("/api/torrents")
def list_torrents() -> list[dict[str, Any]]:
    torrents = run_qb_action("list_torrents")
    if settings.auto_pause_on_complete:
        for torrent in torrents:
            pause_if_completed_uploading(torrent)
    return [to_simple_torrent(torrent) for torrent in torrents]


@app.get("/api/torrents/{torrent_hash}/files")
def get_torrent_files(torrent_hash: str) -> list[dict[str, Any]]:
    return run_qb_action("get_files", torrent_hash)


@app.post("/api/torrents/{torrent_hash}/select-file")
def select_file(
    torrent_hash: str,
    payload: SelectFileRequest,
) -> dict[str, str]:
    run_qb_action("select_only_one_file", torrent_hash, payload.file_id)
    return {"status": "selected"}


@app.post("/api/torrents/{torrent_hash}/start")
def start_torrent(torrent_hash: str) -> dict[str, str]:
    run_qb_action("start", torrent_hash)
    return {"status": "started"}


@app.post("/api/torrents/{torrent_hash}/pause")
def pause_torrent(torrent_hash: str) -> dict[str, str]:
    run_qb_action("pause", torrent_hash)
    return {"status": "paused"}


@app.delete("/api/torrents/{torrent_hash}")
def delete_torrent(torrent_hash: str) -> dict[str, str]:
    run_qb_action("delete", torrent_hash, delete_files=True)
    return {"status": "deleted"}


@app.get("/api/completed-files")
def completed_files() -> list[dict[str, Any]]:
    download_dir = settings.download_complete_dir
    if not download_dir.exists():
        return []

    results: list[dict[str, Any]] = []
    for file_path in sorted(download_dir.rglob("*")):
        if file_path.is_file() and is_visible_completed_file(file_path, download_dir):
            relative_path = file_path.relative_to(download_dir).as_posix()
            stat = file_path.stat()
            results.append(
                {
                    "name": relative_path,
                    "path": str(Path(relative_path)),
                    "url": f"{settings.stream_base_url}/{quote(relative_path)}",
                    "modified_at": timestamp_to_iso(stat.st_mtime),
                }
            )

    return results


def is_visible_completed_file(file_path: Path, download_dir: Path) -> bool:
    relative_path = file_path.relative_to(download_dir)
    path_parts = [part.lower() for part in relative_path.parts]
    support_dirs = {"screens", "screenshots", "sample", "samples"}
    hidden_extensions = {".nfo", ".txt", ".jpg", ".jpeg", ".png", ".webp"}
    preferred_extensions = {".mp4", ".mkv", ".avi", ".mov", ".webm", ".zip", ".rar", ".7z", ".iso", ".pdf"}

    if any(part in support_dirs for part in path_parts[:-1]):
        return False

    if "sample" in file_path.stem.lower():
        return False

    suffix = file_path.suffix.lower()
    if suffix in hidden_extensions:
        return False

    return suffix in preferred_extensions


def timestamp_to_iso(value: Any) -> str | None:
    try:
        timestamp = float(value)
    except (TypeError, ValueError):
        return None

    if timestamp <= 0:
        return None

    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat()


def to_simple_torrent(torrent: dict[str, Any]) -> dict[str, Any]:
    progress = float(torrent.get("progress", 0))
    state = str(torrent.get("state", ""))
    is_complete = progress >= 1
    return {
        "hash": torrent.get("hash", ""),
        "name": torrent.get("name", ""),
        "status": to_seedr_status(state, progress),
        "progress_percent": round(progress * 100, 2),
        "size": torrent.get("size", 0),
        "download_speed": torrent.get("dlspeed", 0),
        "eta": 0 if is_complete else torrent.get("eta", 0),
        "is_complete": is_complete,
        "added_at": timestamp_to_iso(torrent.get("added_on")),
        "completed_at": timestamp_to_iso(torrent.get("completion_on")),
    }


def to_seedr_status(state: str, progress: float) -> str:
    if progress >= 1:
        return "Completed"
    if state in {"error", "missingFiles", "unknown"}:
        return "Failed"
    if state in {"metaDL", "checkingDL", "queuedDL", "stalledDL", "pausedDL"}:
        return "Waiting"
    return "Downloading"


def pause_if_completed_uploading(torrent: dict[str, Any]) -> None:
    state = str(torrent.get("state", ""))
    progress = float(torrent.get("progress", 0))
    torrent_hash = str(torrent.get("hash", ""))
    upload_states = {"uploading", "stalledUP", "queuedUP", "checkingUP", "forcedUP", "seeding"}
    paused_complete_states = {"pausedUP"}

    if state in paused_complete_states or not torrent_hash:
        return

    if progress < 1 and state not in upload_states:
        return

    run_qb_action("pause", torrent_hash)
    torrent["state"] = "pausedUP"


async def auto_pause_monitor() -> None:
    while True:
        try:
            torrents = qb.list_torrents()
            for torrent in torrents:
                pause_if_completed_uploading(torrent)
        except (RuntimeError, RequestException):
            pass

        await asyncio.sleep(15)
