import asyncio
import json
import shutil
import subprocess
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


class ExtractSubtitleRequest(BaseModel):
    path: str


class VideoProgressRequest(BaseModel):
    path: str
    timeMs: int
    durationMs: int


VIDEO_PROGRESS_FILE = settings.download_complete_dir.parent / "video_progress.json"


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


@app.post("/api/video-progress")
def save_video_progress(payload: VideoProgressRequest) -> dict[str, Any]:
    path = payload.path.strip()
    if not path:
        raise HTTPException(status_code=400, detail="Path is required.")

    time_ms = max(0, int(payload.timeMs))
    duration_ms = max(0, int(payload.durationMs))
    watched_percent = progress_percent(time_ms, duration_ms)
    updated_at = datetime.now(timezone.utc).isoformat()

    progress = read_video_progress()
    record = {
        "path": path,
        "timeMs": time_ms,
        "durationMs": duration_ms,
        "watchedPercent": watched_percent,
        "updatedAt": updated_at,
    }
    progress[path] = record
    write_video_progress(progress)
    return record


@app.get("/api/video-progress")
def get_video_progress() -> list[dict[str, Any]]:
    return list(read_video_progress().values())


# Subtitle codecs ffmpeg can convert to SubRip (.srt). Image-based codecs
# (PGS/VobSub/DVD/DVB) carry bitmaps, not text, so they cannot become .srt
# without OCR — they are detected and skipped.
TEXT_SUBTITLE_CODECS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt"}
IMAGE_SUBTITLE_CODECS = {
    "hdmv_pgs_subtitle",
    "dvd_subtitle",
    "dvbsub",
    "dvb_subtitle",
    "xsub",
}
# Hard limits so a stuck/huge probe or extract can't wedge the request.
FFPROBE_TIMEOUT_S = 30
FFMPEG_TIMEOUT_S = 120


@app.post("/api/subtitles/extract")
def extract_subtitle(payload: ExtractSubtitleRequest) -> dict[str, Any]:
    """Extract the first (English-preferred) embedded TEXT subtitle track of a
    completed video into a sidecar `<stem>.srt` beside it, which Nginx already
    serves at `/files/...`. On-demand only — does not run in the background.

    Statuses: extracted | exists | no_text_subtitles | image_subtitles_only |
    ffmpeg_unavailable | extraction_failed. The `.srt` stream URL is included
    whenever the file exists or was created.
    """
    video_path = resolve_completed_path(payload.path)
    srt_path = video_path.with_suffix(".srt")

    # Never overwrite an existing sidecar (could be user-provided).
    if srt_path.exists():
        return {"status": "exists", "url": srt_stream_url(srt_path)}

    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        return {"status": "ffmpeg_unavailable"}

    streams = probe_subtitle_streams(video_path)
    if streams is None:
        return {"status": "extraction_failed"}

    text_streams = [s for s in streams if s["codec"] in TEXT_SUBTITLE_CODECS]
    if not text_streams:
        # Distinguish "had only image subs" from "no subtitles at all" so the
        # caller can explain why no sidecar appeared.
        has_image = any(s["codec"] in IMAGE_SUBTITLE_CODECS for s in streams)
        return {"status": "image_subtitles_only" if has_image else "no_text_subtitles"}

    chosen = pick_subtitle_stream(text_streams)
    if not extract_to_srt(video_path, chosen["sub_index"], srt_path):
        return {"status": "extraction_failed"}

    return {"status": "extracted", "url": srt_stream_url(srt_path)}


def resolve_completed_path(relative_path: str) -> Path:
    """Resolve a client-supplied relative path to an existing file UNDER the
    completed-downloads dir. Rejects traversal/escape and non-files with 400/404
    so a caller can never read outside the served tree."""
    download_dir = settings.download_complete_dir.resolve()
    candidate = (download_dir / relative_path).resolve()

    if not candidate.is_relative_to(download_dir):
        raise HTTPException(status_code=400, detail="Invalid path.")
    if not candidate.is_file():
        raise HTTPException(status_code=404, detail="File not found.")
    return candidate


def srt_stream_url(srt_path: Path) -> str:
    """Build the Nginx stream URL for a sidecar `.srt`, matching the scheme the
    completed-files listing uses for videos."""
    relative = srt_path.relative_to(settings.download_complete_dir.resolve()).as_posix()
    return f"{settings.stream_base_url}/{quote(relative)}"


def probe_subtitle_streams(video_path: Path) -> list[dict[str, Any]] | None:
    """Return the video's subtitle streams as `{sub_index, codec, language}`,
    where `sub_index` is the subtitle-relative index ffmpeg's `0:s:N` map uses.
    Returns None on probe failure (so the caller reports extraction_failed)."""
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-select_streams", "s",
                "-show_entries", "stream=codec_name:stream_tags=language",
                "-of", "json",
                str(video_path),
            ],
            capture_output=True,
            text=True,
            timeout=FFPROBE_TIMEOUT_S,
        )
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout or "{}")
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return None

    streams: list[dict[str, Any]] = []
    for sub_index, stream in enumerate(data.get("streams", [])):
        streams.append(
            {
                "sub_index": sub_index,
                "codec": (stream.get("codec_name") or "").lower(),
                "language": (stream.get("tags", {}).get("language") or "").lower(),
            }
        )
    return streams


def pick_subtitle_stream(text_streams: list[dict[str, Any]]) -> dict[str, Any]:
    """Prefer an English text track (`eng`/`en` language tag); otherwise the
    first text track. `text_streams` is assumed non-empty."""
    for stream in text_streams:
        if stream["language"] in {"eng", "en"}:
            return stream
    return text_streams[0]


def extract_to_srt(video_path: Path, sub_index: int, srt_path: Path) -> bool:
    """Convert subtitle stream `0:s:<sub_index>` to a SubRip `.srt`. Returns
    True on success. Removes a partial file if ffmpeg fails, so a later retry
    isn't blocked by a half-written sidecar."""
    try:
        result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i", str(video_path),
                "-map", f"0:s:{sub_index}",
                "-c:s", "srt",
                str(srt_path),
            ],
            capture_output=True,
            text=True,
            timeout=FFMPEG_TIMEOUT_S,
        )
    except (subprocess.SubprocessError, OSError):
        srt_path.unlink(missing_ok=True)
        return False

    if result.returncode != 0 or not srt_path.exists() or srt_path.stat().st_size == 0:
        srt_path.unlink(missing_ok=True)
        return False
    return True


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


def progress_percent(time_ms: int, duration_ms: int) -> float:
    if duration_ms <= 0:
        return 0.0
    return round(min(max(time_ms / duration_ms * 100, 0), 100), 2)


def read_video_progress() -> dict[str, dict[str, Any]]:
    try:
        data = json.loads(VIDEO_PROGRESS_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        str(path): record
        for path, record in data.items()
        if isinstance(path, str) and isinstance(record, dict)
    }


def write_video_progress(progress: dict[str, dict[str, Any]]) -> None:
    VIDEO_PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = VIDEO_PROGRESS_FILE.with_suffix(".tmp")
    tmp_path.write_text(
        json.dumps(progress, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    tmp_path.replace(VIDEO_PROGRESS_FILE)


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
