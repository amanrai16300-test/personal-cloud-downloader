import asyncio
import calendar
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import unicodedata
from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from markitdown import MarkItDown
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
THUMBNAIL_CACHE_DIR_NAME = "_cloudbox-thumbnails"
THUMBNAIL_TIMESTAMPS_SECONDS = (10, 30, 60, 1)
MIN_THUMBNAIL_BYTES = 2 * 1024
NETWORK_INTERFACE = "enp0s6"
VNSTAT_TIMEOUT_SECONDS = 5
STORAGE_PATHS = ("/srv/personal-cloud",)
TRENDS_FILE = Path("/tmp/trends.json")
MARKDOWN_ALLOWED_EXTENSIONS = {
    ".pdf",
    ".docx",
    ".pptx",
    ".xlsx",
    ".xls",
    ".csv",
    ".json",
    ".xml",
    ".html",
    ".htm",
    ".txt",
    ".text",
    ".md",
    ".markdown",
    ".epub",
}
MARKDOWN_MAX_UPLOAD_BYTES = 25 * 1024 * 1024
MARKDOWN_CONVERSION_TIMEOUT_SECONDS = 60


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


@app.get("/api/trends")
def trends() -> dict[str, Any]:
    try:
        data = json.loads(TRENDS_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"error": "data not available"}

    required_sections = ("global_movies", "global_series", "india_movies", "india_series")
    if not isinstance(data, dict):
        return {"error": "data not available"}
    if not isinstance(data.get("updated_at"), str):
        return {"error": "data not available"}
    if any(not isinstance(data.get(section), list) for section in required_sections):
        return {"error": "data not available"}

    return data


@app.get("/api/network-usage")
def network_usage() -> dict[str, Any]:
    storage = get_storage_usage()
    data = run_vnstat_json()
    if data is not None:
        data["storage"] = storage
        return data

    text = run_vnstat_text()
    if text is not None:
        return {
            "status": "ok",
            "interface": NETWORK_INTERFACE,
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "format": "text",
            "raw": text,
            "storage": storage,
        }

    raise HTTPException(status_code=503, detail="vnstat is unavailable or returned no network data.")


@app.post("/api/convert-markdown")
async def convert_markdown(file: UploadFile = File(...)) -> dict[str, str]:
    filename = Path(file.filename or "").name
    extension = Path(filename).suffix.lower()
    if extension not in MARKDOWN_ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Unsupported file type.")

    temp_path: Path | None = None
    size = 0
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=extension) as temp_file:
            temp_path = Path(temp_file.name)
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > MARKDOWN_MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail="File is too large.")
                temp_file.write(chunk)

        markdown = await asyncio.wait_for(
            asyncio.to_thread(convert_local_markdown_file, temp_path),
            timeout=MARKDOWN_CONVERSION_TIMEOUT_SECONDS,
        )
        return {
            "filename": filename,
            "extension": extension,
            "markdown": clean_markdown_output(markdown),
            "conversion_mode": "local",
        }
    except asyncio.TimeoutError as exc:
        raise HTTPException(status_code=504, detail="Markdown conversion timed out.") from exc
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Markdown conversion failed.") from exc
    finally:
        await file.close()
        if temp_path is not None:
            with suppress(OSError):
                temp_path.unlink(missing_ok=True)


def convert_local_markdown_file(path: Path) -> str:
    result = MarkItDown(enable_plugins=False).convert_local(path)
    markdown = getattr(result, "text_content", None)
    if markdown is None:
        markdown = getattr(result, "markdown", "")
    return str(markdown)


def clean_markdown_output(markdown: str) -> str:
    try:
        cleaned = "".join(
            char
            for char in markdown
            if char in {"\n", "\r", "\t", " "}
            or (not char.isspace() and not unicodedata.category(char).startswith("C"))
        )
        yen_mojibake = "\uff82\uff65"
        apostrophe_mojibake = "\uff8a\uff7c"
        replacements = (
            (yen_mojibake, "¥"),
            (r"\\uff82\\uff65", "¥"),
            (f"{apostrophe_mojibake}s", "'s"),
            (r"\\uff8a\\uff7cs", "'s"),
            (f"{apostrophe_mojibake} pension", "' pension"),
            (r"\\uff8a\\uff7c pension", "' pension"),
            ("\u7ab6\u5eec", '"'),
            ("\u7ab6\u30fb", '"'),
            ("9001800 8 hours per day)", "9:00-18:00 (8 hours per day)"),
        )
        for old, new in replacements:
            cleaned = cleaned.replace(old, new)
        return re.sub(r"([.!?])(\d+)(?=[A-Z][a-z])", r"\1 \2 ", cleaned)
    except Exception:
        return markdown


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
    ensure_missing_video_thumbnails(download_dir)

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
            item = {
                "name": relative_path,
                "path": str(Path(relative_path)),
                "url": f"{settings.stream_base_url}/{quote(relative_path)}",
                "modified_at": timestamp_to_iso(stat.st_mtime),
            }
            thumbnail_url = thumbnail_url_for_completed_video(file_path, download_dir)
            if thumbnail_url:
                item["thumbnail_url"] = thumbnail_url
            results.append(item)

    return results


def ensure_missing_video_thumbnails(download_dir: Path) -> None:
    for video_path in iter_completed_video_files(download_dir):
        ensure_video_thumbnail(video_path, download_dir)


def iter_completed_video_files(download_dir: Path):
    download_root = download_dir.resolve()
    for file_path in sorted(download_root.rglob("*")):
        try:
            resolved = resolve_safe_download_target(file_path, download_root)
            relative = resolved.relative_to(download_root)
        except ValueError:
            continue

        if THUMBNAIL_CACHE_DIR_NAME in relative.parts:
            continue
        if not resolved.is_file() or not is_video_file(resolved):
            continue

        yield resolved


def thumbnail_url_for_completed_video(file_path: Path, download_dir: Path) -> str | None:
    if not is_video_file(file_path):
        return None

    thumbnail_path = ensure_video_thumbnail(file_path, download_dir)
    if thumbnail_path is None:
        return None

    try:
        relative = thumbnail_path.relative_to(download_dir.resolve()).as_posix()
    except ValueError:
        return None
    return f"{settings.stream_base_url}/{quote(relative)}"


def ensure_video_thumbnail(file_path: Path, download_dir: Path) -> Path | None:
    download_root = download_dir.resolve()

    try:
        video_path = resolve_safe_download_target(file_path, download_root)
        if not video_path.is_file() or not is_video_file(video_path):
            return None
    except ValueError:
        return None

    if shutil.which("ffmpeg") is None:
        return None

    try:
        relative = video_path.relative_to(download_root).as_posix()
        stat = video_path.stat()
    except (OSError, ValueError):
        return None

    cache_dir = download_root / THUMBNAIL_CACHE_DIR_NAME
    cache_key = hashlib.sha256(f"{relative}:{stat.st_size}:{stat.st_mtime_ns}".encode("utf-8")).hexdigest()

    try:
        thumbnail_path = resolve_safe_download_target(cache_dir / f"{cache_key}.jpg", download_root)
    except ValueError:
        return None

    if is_valid_thumbnail(thumbnail_path):
        return thumbnail_path
    if thumbnail_path.exists():
        try:
            thumbnail_path.unlink()
        except OSError:
            return None

    try:
        cache_dir.mkdir(exist_ok=True)
    except OSError:
        return None

    for timestamp in THUMBNAIL_TIMESTAMPS_SECONDS:
        if extract_video_thumbnail(video_path, thumbnail_path, timestamp):
            return thumbnail_path

    try:
        thumbnail_path.unlink(missing_ok=True)
    except OSError:
        pass
    print(f"Warning: thumbnail generation failed for {relative}")
    return None


def is_valid_thumbnail(thumbnail_path: Path) -> bool:
    try:
        return thumbnail_path.is_file() and thumbnail_path.stat().st_size >= MIN_THUMBNAIL_BYTES
    except OSError:
        return False


def extract_video_thumbnail(video_path: Path, thumbnail_path: Path, timestamp_seconds: int) -> bool:
    tmp_path = thumbnail_path.with_name(f"{thumbnail_path.stem}.tmp.jpg")
    tmp_path.unlink(missing_ok=True)

    try:
        result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-ss", str(timestamp_seconds),
                "-i", str(video_path),
                "-frames:v", "1",
                "-q:v", "3",
                "-vf", "scale=320:-1",
                str(tmp_path),
            ],
            capture_output=True,
            text=True,
            timeout=FFMPEG_TIMEOUT_S,
        )
    except (subprocess.SubprocessError, OSError):
        tmp_path.unlink(missing_ok=True)
        return False

    if result.returncode != 0 or not is_valid_thumbnail(tmp_path):
        tmp_path.unlink(missing_ok=True)
        return False

    try:
        tmp_path.replace(thumbnail_path)
    except OSError:
        tmp_path.unlink(missing_ok=True)
        return False
    return True


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

    if THUMBNAIL_CACHE_DIR_NAME in relative_path.parts:
        return False

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


def run_vnstat_json() -> dict[str, Any] | None:
    result = run_fixed_command(["vnstat", "-i", NETWORK_INTERFACE, "--json"])
    if result is None:
        return None

    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return None

    interfaces = payload.get("interfaces")
    if not isinstance(interfaces, list) or not interfaces:
        return None

    interface = next(
        (item for item in interfaces if isinstance(item, dict) and item.get("name") == NETWORK_INTERFACE),
        interfaces[0],
    )
    if not isinstance(interface, dict):
        return None

    traffic = interface.get("traffic")
    if not isinstance(traffic, dict):
        return None

    now = datetime.now(timezone.utc)
    month_rows = [row for row in traffic.get("month", []) if isinstance(row, dict)]
    day_rows = [row for row in traffic.get("day", []) if isinstance(row, dict)]
    current_month = find_current_month(month_rows, now)
    current_day = find_current_day(day_rows, now)
    daily = [format_usage_row(row, "day", now) for row in day_rows[-14:]]

    return {
        "status": "ok",
        "interface": str(interface.get("name") or NETWORK_INTERFACE),
        "updated_at": now.isoformat(),
        "format": "json",
        "month": format_usage_row(current_month, "month", now) if current_month else None,
        "today": format_usage_row(current_day, "day", now) if current_day else None,
        "daily": [row for row in daily if row is not None],
    }


def run_vnstat_text() -> str | None:
    result = run_fixed_command(["vnstat", "-i", NETWORK_INTERFACE])
    if result is None:
        return None
    output = (result.stdout or "").strip()
    return output or None


def run_fixed_command(command: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=VNSTAT_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if result.returncode != 0:
        return None
    return result


def get_storage_usage() -> dict[str, Any]:
    disks: list[dict[str, Any]] = []
    errors: list[str] = []
    for path in STORAGE_PATHS:
        if path != "/" and not Path(path).exists():
            continue
        result = run_fixed_command(["df", "-B1", path])
        if result is None:
            errors.append(f"Could not load storage usage for {path}.")
            continue
        disk = parse_df_output(result.stdout, path)
        if disk is None:
            errors.append(f"Could not parse storage usage for {path}.")
            continue
        disks.append(disk)

    status = "ok" if disks and not errors else "partial" if disks else "error"
    storage: dict[str, Any] = {"status": status, "disks": disks}
    if errors:
        storage["error"] = " ".join(errors)
    return storage


def parse_df_output(output: str, path: str) -> dict[str, Any] | None:
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        return None
    parts = lines[-1].split()
    if len(parts) < 6:
        return None
    try:
        total_bytes = int(parts[1])
        used_bytes = int(parts[2])
        available_bytes = int(parts[3])
        used_percent = float(parts[4].rstrip("%"))
    except ValueError:
        return None

    return {
        "path": path,
        "mount": parts[5],
        "used_bytes": used_bytes,
        "total_bytes": total_bytes,
        "available_bytes": available_bytes,
        "used_percent": used_percent,
        "used": format_bytes(used_bytes),
        "total": format_bytes(total_bytes),
        "available": format_bytes(available_bytes),
    }


def find_current_month(rows: list[dict[str, Any]], now: datetime) -> dict[str, Any] | None:
    return next(
        (
            row for row in reversed(rows)
            if row_date_part(row, "year") == now.year and row_date_part(row, "month") == now.month
        ),
        rows[-1] if rows else None,
    )


def find_current_day(rows: list[dict[str, Any]], now: datetime) -> dict[str, Any] | None:
    return next(
        (
            row for row in reversed(rows)
            if (
                row_date_part(row, "year") == now.year
                and row_date_part(row, "month") == now.month
                and row_date_part(row, "day") == now.day
            )
        ),
        rows[-1] if rows else None,
    )


def row_date_part(row: dict[str, Any], part: str) -> int | None:
    date = row.get("date")
    if not isinstance(date, dict):
        return None
    value = date.get(part)
    return int(value) if isinstance(value, int) else None


def format_usage_row(row: dict[str, Any], period: str, now: datetime) -> dict[str, Any] | None:
    rx = int(row.get("rx", 0) or 0)
    tx = int(row.get("tx", 0) or 0)
    total = rx + tx
    avg_bps = average_bits_per_second(total, row, period, now)
    result: dict[str, Any] = {
        "date": format_vnstat_date(row, period),
        "rx_bytes": rx,
        "tx_bytes": tx,
        "total_bytes": total,
        "rx": format_bytes(rx),
        "tx": format_bytes(tx),
        "total": format_bytes(total),
        "avg_rate_bps": avg_bps,
        "avg_rate": format_bps(avg_bps),
    }
    if period == "month":
        estimate = estimate_monthly_total(total, row, now)
        result["estimated_total_bytes"] = estimate
        result["estimated_total"] = format_bytes(estimate)
    return result


def format_vnstat_date(row: dict[str, Any], period: str) -> str:
    date = row.get("date")
    if not isinstance(date, dict):
        return ""
    year = int(date.get("year", 0) or 0)
    month = int(date.get("month", 0) or 0)
    day = int(date.get("day", 0) or 0)
    if period == "month" and year and month:
        return f"{year:04d}-{month:02d}"
    if year and month and day:
        return f"{year:04d}-{month:02d}-{day:02d}"
    return ""


def average_bits_per_second(total_bytes: int, row: dict[str, Any], period: str, now: datetime) -> float:
    date = row.get("date")
    if not isinstance(date, dict):
        return 0.0
    year = int(date.get("year", now.year) or now.year)
    month = int(date.get("month", now.month) or now.month)
    day = int(date.get("day", 1) or 1)
    start = datetime(year, month, 1, tzinfo=timezone.utc)
    if period == "day":
        start = datetime(year, month, day, tzinfo=timezone.utc)
    elapsed = max((now - start).total_seconds(), 1.0)
    return total_bytes * 8 / elapsed


def estimate_monthly_total(total_bytes: int, row: dict[str, Any], now: datetime) -> int:
    if row_date_part(row, "year") != now.year or row_date_part(row, "month") != now.month:
        return total_bytes
    month_start = datetime(now.year, now.month, 1, tzinfo=timezone.utc)
    elapsed = max((now - month_start).total_seconds(), 1.0)
    days_in_month = calendar.monthrange(now.year, now.month)[1]
    month_seconds = days_in_month * 24 * 60 * 60
    return int(total_bytes * (month_seconds / elapsed))


def format_bytes(value: int) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.1f} {unit}" if unit != "B" else f"{int(amount)} B"
        amount /= 1024
    return f"{value} B"


def format_bps(value: float) -> str:
    units = ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s"]
    amount = float(value)
    for unit in units:
        if amount < 1000 or unit == units[-1]:
            return f"{amount:.1f} {unit}"
        amount /= 1000
    return f"{value:.1f} bit/s"


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
