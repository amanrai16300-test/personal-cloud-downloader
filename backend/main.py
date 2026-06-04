import asyncio
import json
import re
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
def delete_torrent(torrent_hash: str) -> dict[str, Any]:
    torrent = find_torrent(torrent_hash)
    candidates = build_delete_candidates(torrent)
    result: dict[str, Any] = {
        "torrent_hash": torrent_hash,
        "torrent_name": str(torrent.get("name", "")) if torrent else None,
        "qbittorrent_delete_result": None,
        "candidate_paths_checked": [str(path) for path in candidates],
        "deleted_file_paths": [],
        "deleted_folder_paths": [],
        "warnings": [] if torrent else ["Torrent was not found before delete."],
    }

    result["qbittorrent_delete_result"] = run_qb_action("delete", torrent_hash, delete_files=True)
    delete_completed_candidates(candidates, result)
    return result


def find_torrent(torrent_hash: str) -> dict[str, Any] | None:
    for torrent in run_qb_action("list_torrents"):
        if str(torrent.get("hash", "")) == torrent_hash:
            return torrent
    return None


def build_delete_candidates(torrent: dict[str, Any] | None) -> list[Path]:
    if torrent is None:
        return []

    download_root = settings.download_complete_dir.resolve()
    raw_candidates: list[Path] = []
    name = str(torrent.get("name") or "").strip()
    content_path = str(torrent.get("content_path") or "").strip()
    save_path = str(torrent.get("save_path") or "").strip()

    if content_path:
        content = Path(content_path)
        raw_candidates.extend([content, download_root / content.name, download_root / content.stem])
    if save_path and name:
        raw_candidates.append(Path(save_path) / name)
    if name:
        raw_candidates.append(download_root / name)

    safe_candidates: list[Path] = []
    seen: set[Path] = set()
    for candidate in raw_candidates:
        try:
            safe = resolve_safe_download_target(candidate, download_root)
        except ValueError:
            continue
        if safe not in seen:
            seen.add(safe)
            safe_candidates.append(safe)

    return safe_candidates


def delete_completed_candidates(candidates: list[Path], result: dict[str, Any]) -> None:
    for candidate in candidates:
        try:
            if candidate.is_dir():
                shutil.rmtree(candidate)
                result["deleted_folder_paths"].append(str(candidate))
            elif candidate.is_file():
                delete_file_with_sidecars(candidate, result)
                moved_folder = candidate.parent / candidate.stem
                if moved_folder.is_dir():
                    shutil.rmtree(moved_folder)
                    result["deleted_folder_paths"].append(str(moved_folder))
        except OSError as exc:
            result["warnings"].append(f"Failed to delete {candidate}: {exc}")


def delete_file_with_sidecars(file_path: Path, result: dict[str, Any]) -> None:
    paths = [file_path, file_path.with_suffix(".srt"), file_path.with_suffix(".vtt")]
    for path in paths:
        if path.is_file():
            path.unlink()
            result["deleted_file_paths"].append(str(path))


@app.get("/api/completed-files")
def completed_files() -> list[dict[str, Any]]:
    download_dir = settings.download_complete_dir
    if not download_dir.exists():
        return []

    organize_loose_completed_videos(download_dir)

    results: list[dict[str, Any]] = []
    for file_path in sorted(download_dir.rglob("*")):
        if not file_path.is_file():
            continue

        if file_path.suffix.lower() in {".srt", ".vtt"}:
            try:
                sanitize_subtitle_file(file_path, create_backup=True)
            except OSError:
                pass

        if is_visible_completed_file(file_path, download_dir):
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


def organize_loose_completed_videos(download_dir: Path) -> None:
    download_root = download_dir.resolve()
    for file_path in sorted(download_root.iterdir()):
        try:
            if not file_path.is_file() or not is_video_file(file_path):
                continue

            target_dir = resolve_safe_download_target(download_root / file_path.stem, download_root)
            if target_dir.exists() and not target_dir.is_dir():
                continue

            target_dir.mkdir(exist_ok=True)
            move_into_directory(file_path, target_dir, download_root)

            for suffix in (".srt", ".vtt"):
                sidecar = download_root / f"{file_path.stem}{suffix}"
                if sidecar.is_file():
                    move_into_directory(sidecar, target_dir, download_root)
        except (OSError, ValueError):
            continue


def move_into_directory(file_path: Path, target_dir: Path, download_root: Path) -> None:
    source = resolve_safe_download_target(file_path, download_root)
    destination = resolve_safe_download_target(target_dir / file_path.name, download_root)
    if destination.exists():
        return
    shutil.move(str(source), str(destination))


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
SUBTITLE_TAG_RE = re.compile(r"</?[A-Za-z][A-Za-z0-9]*(?:\s+[^<>]*)?>")
SUBTITLE_ASS_OVERRIDE_RE = re.compile(r"\{[^{}]*\\[^{}]*\}")
SUBTITLE_ENTITY_RE = re.compile(r"&amp;|&lt;|&gt;|&quot;|&#39;")
SUBTITLE_ENTITY_REPLACEMENTS = {
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": '"',
    "&#39;": "'",
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
        sanitize_subtitle_file(srt_path, create_backup=True)
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

    sanitize_subtitle_file(srt_path, create_backup=False)
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


def resolve_safe_download_target(candidate: Path, download_root: Path) -> Path:
    resolved_root = download_root.resolve()
    resolved = candidate.resolve()
    if resolved == resolved_root or not resolved.is_relative_to(resolved_root):
        raise ValueError("Path is outside completed downloads root.")
    return resolved


def srt_stream_url(srt_path: Path) -> str:
    """Build the Nginx stream URL for a sidecar `.srt`, matching the scheme the
    completed-files listing uses for videos."""
    relative = srt_path.relative_to(settings.download_complete_dir.resolve()).as_posix()
    return f"{settings.stream_base_url}/{quote(relative)}"


def sanitize_subtitle_file(subtitle_path: Path, *, create_backup: bool) -> bool:
    """Clean cue dialogue text in .srt/.vtt files under completed downloads."""
    completed_root = settings.download_complete_dir.resolve()
    resolved = subtitle_path.resolve()
    if resolved.suffix.lower() not in {".srt", ".vtt"} or not resolved.is_relative_to(completed_root):
        return False

    try:
        original = resolved.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False

    sanitized = sanitize_subtitle_content(original)
    if sanitized == original:
        return False

    try:
        if create_backup:
            backup_path = subtitle_backup_path(resolved)
            if not backup_path.exists():
                shutil.copy2(resolved, backup_path)
        resolved.write_text(sanitized, encoding="utf-8")
    except OSError:
        return False
    return True


def subtitle_backup_path(subtitle_path: Path) -> Path:
    return subtitle_path.with_name(f"{subtitle_path.name}.bak")


def sanitize_subtitle_content(content: str) -> str:
    lines = content.splitlines(keepends=True)
    sanitized_lines: list[str] = []
    in_dialogue = False

    for line in lines:
        text, newline = split_subtitle_newline(line)
        stripped = text.strip()

        if stripped == "":
            in_dialogue = False
            sanitized_lines.append(line)
            continue

        if is_subtitle_timing_line(text):
            in_dialogue = True
            sanitized_lines.append(line)
            continue

        if in_dialogue:
            sanitized_lines.append(sanitize_subtitle_dialogue_text(text) + newline)
        else:
            sanitized_lines.append(line)

    return "".join(sanitized_lines)


def split_subtitle_newline(line: str) -> tuple[str, str]:
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n"):
        return line[:-1], "\n"
    if line.endswith("\r"):
        return line[:-1], "\r"
    return line, ""


def is_subtitle_timing_line(text: str) -> bool:
    return "-->" in text


def sanitize_subtitle_dialogue_text(text: str) -> str:
    decoded = SUBTITLE_ENTITY_RE.sub(
        lambda match: SUBTITLE_ENTITY_REPLACEMENTS[match.group(0)],
        text,
    )
    without_ass_overrides = SUBTITLE_ASS_OVERRIDE_RE.sub("", decoded)
    return SUBTITLE_TAG_RE.sub("", without_ass_overrides)


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


def is_video_file(file_path: Path) -> bool:
    return file_path.suffix.lower() in {".mp4", ".mkv", ".avi", ".mov", ".webm"}


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
