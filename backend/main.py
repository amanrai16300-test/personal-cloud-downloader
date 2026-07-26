import asyncio
import calendar
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import time
import tempfile
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from difflib import SequenceMatcher
from io import BytesIO
from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any
from urllib.parse import quote, urljoin, urlparse

from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from markitdown import MarkItDown
from pydantic import BaseModel
import requests
from requests import RequestException

from qb_client import QBittorrentClient
from settings import settings

app = FastAPI(title="Personal Cloud Downloader")
qb = QBittorrentClient()
monitor_task: asyncio.Task[None] | None = None
markdown_conversion_tasks: set[asyncio.Task[Any]] = set()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://100.95.39.107:8090"],
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


class ConvertMarkdownURLRequest(BaseModel):
    url: str


VIDEO_PROGRESS_FILE = settings.download_complete_dir.parent / "video_progress.json"
_video_progress_lock = Lock()
HOME_SERVER_LOCATION = "Oracle · Tokyo"
WATCHED_COMPLETION_PERCENT = 90.0
# Raw playable videos returned for `recently_added`. The client groups TV
# episodes into series and then shows only the first few unique cards, so the
# backend must over-fetch (a single series can span many episodes) to leave the
# client enough rows to fill its visible slots.
HOME_RECENTLY_ADDED_LIMIT = 40
HOME_NETWORK_SAMPLE_SECONDS = 0.5
# TMDB artwork enrichment for Home. Reuses the same TMDB scheme as
# scripts/fetch_trends.py (api.themoviedb.org/3, TMDB_API_KEY env var, w500
# images) so credentials and request shape stay consistent. Key is read from
# the environment and never returned to clients — only image CDN URLs are.
TMDB_API_BASE_URL = "https://api.themoviedb.org/3"
TMDB_POSTER_BASE_URL = "https://image.tmdb.org/t/p/w500"
TMDB_BACKDROP_BASE_URL = "https://image.tmdb.org/t/p/w780"
TMDB_REQUEST_TIMEOUT_SECONDS = 6
TMDB_CACHE_TTL_SECONDS = 6 * 60 * 60
TMDB_MAX_WORKERS = 3
TMDB_MAX_PENDING_JOBS = 32
# Module-level cache of TMDB lookups keyed by normalized title+year+media_type.
# Stores hits AND no-match (None) results with a timestamp so a Home refresh
# does not re-search TMDB; entries expire after TMDB_CACHE_TTL_SECONDS.
_tmdb_cache: dict[str, tuple[float, dict[str, Any] | None]] = {}
_tmdb_executor = ThreadPoolExecutor(
    max_workers=TMDB_MAX_WORKERS,
    thread_name_prefix="cloudbox-tmdb",
)
_tmdb_jobs: set[str] = set()
_tmdb_jobs_lock = Lock()
QB_ACTIVE_STATES = {
    "downloading",
    "metaDL",
    "forcedDL",
    "stalledDL",
    "checkingDL",
    "queuedDL",
    "allocating",
    "uploading",
    "forcedUP",
    "stalledUP",
    "queuedUP",
    "checkingUP",
    "seeding",
}
QB_SAFE_TO_MOVE_STATES = {"pausedUP", "stoppedUP"}
THUMBNAIL_CACHE_DIR_NAME = "_cloudbox-thumbnails"
THUMBNAIL_CACHE_VERSION = "v3"
MIN_THUMBNAIL_BYTES = 2 * 1024
THUMBNAIL_MAX_WORKERS = 2
THUMBNAIL_MAX_PENDING_JOBS = 32
_thumbnail_executor = ThreadPoolExecutor(
    max_workers=THUMBNAIL_MAX_WORKERS,
    thread_name_prefix="cloudbox-thumbnail",
)
_thumbnail_jobs: set[Path] = set()
_thumbnail_jobs_lock = Lock()
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
MARKDOWN_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
MARKDOWN_ALLOWED_EXTENSIONS = MARKDOWN_ALLOWED_EXTENSIONS | MARKDOWN_IMAGE_EXTENSIONS
MARKDOWN_MAX_UPLOAD_BYTES = 25 * 1024 * 1024
MARKDOWN_CONVERSION_TIMEOUT_SECONDS = 60
MARKDOWN_TEMP_PREFIX = "cloudbox-markdown-"
MARKDOWN_URL_MAX_BYTES = 5 * 1024 * 1024
MARKDOWN_URL_TIMEOUT_SECONDS = 10
MARKDOWN_URL_MAX_REDIRECTS = 5


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
    _thumbnail_executor.shutdown(wait=False, cancel_futures=True)
    _tmdb_executor.shutdown(wait=False, cancel_futures=True)


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


@app.get("/api/home-dashboard")
def home_dashboard() -> dict[str, Any]:
    now = datetime.now(timezone.utc)

    qb_ok = qbittorrent_reachable()
    storage = get_storage_usage()
    storage_ok = storage_mount_available(storage)

    library = build_home_library(storage)
    downloads = {"active_count": count_active_downloads()}
    network = get_network_rates()

    continue_watching, recently_added = build_home_media()

    return {
        "server": {
            "online": True,
            "location": HOME_SERVER_LOCATION,
            "uptime_seconds": get_uptime_seconds(),
            "last_updated": now.isoformat(),
            "services": {
                "api": True,
                "qbittorrent": qb_ok,
                "storage": storage_ok,
            },
        },
        "library": library,
        "downloads": downloads,
        "network": network,
        "continue_watching": continue_watching,
        "recently_added": recently_added,
    }


def qbittorrent_reachable() -> bool:
    try:
        qb.test_connection()
        return True
    except (RuntimeError, RequestException, ValueError):
        return False


def storage_mount_available(storage: dict[str, Any]) -> bool:
    disks = storage.get("disks") if isinstance(storage, dict) else None
    if not isinstance(disks, list) or not disks:
        return False
    return any(Path(str(disk.get("path"))).exists() for disk in disks if isinstance(disk, dict))


def count_active_downloads() -> int:
    try:
        torrents = qb.list_torrents()
    except (RuntimeError, RequestException, ValueError):
        return 0
    count = 0
    for torrent in torrents:
        if float(torrent.get("progress", 0)) >= 1:
            continue
        if str(torrent.get("state", "")) in QB_ACTIVE_STATES:
            count += 1
    return count


def build_home_library(storage: dict[str, Any]) -> dict[str, Any]:
    download_dir = settings.download_complete_dir
    video_count = 0
    file_count = 0
    if download_dir.exists():
        video_count = sum(1 for _ in iter_completed_video_files(download_dir))
        for file_path in download_dir.rglob("*"):
            if file_path.is_file() and is_visible_completed_file(file_path, download_dir):
                file_count += 1

    used_bytes = 0
    total_bytes = 0
    disks = storage.get("disks") if isinstance(storage, dict) else None
    if isinstance(disks, list) and disks and isinstance(disks[0], dict):
        used_bytes = int(disks[0].get("used_bytes", 0) or 0)
        total_bytes = int(disks[0].get("total_bytes", 0) or 0)

    return {
        "video_count": video_count,
        "file_count": file_count,
        "storage_used_bytes": used_bytes,
        "storage_total_bytes": total_bytes,
    }


def get_uptime_seconds() -> int:
    try:
        first = Path("/proc/uptime").read_text(encoding="utf-8").split()[0]
        return int(float(first))
    except (OSError, ValueError, IndexError):
        return 0


def get_network_rates() -> dict[str, int]:
    first = read_interface_counters()
    if first is None:
        return {"rx_bytes_per_second": 0, "tx_bytes_per_second": 0}
    import time

    time.sleep(HOME_NETWORK_SAMPLE_SECONDS)
    second = read_interface_counters()
    if second is None:
        return {"rx_bytes_per_second": 0, "tx_bytes_per_second": 0}

    rx_delta = max(second[0] - first[0], 0)
    tx_delta = max(second[1] - first[1], 0)
    return {
        "rx_bytes_per_second": int(rx_delta / HOME_NETWORK_SAMPLE_SECONDS),
        "tx_bytes_per_second": int(tx_delta / HOME_NETWORK_SAMPLE_SECONDS),
    }


def read_interface_counters() -> tuple[int, int] | None:
    try:
        lines = Path("/proc/net/dev").read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        name, _, rest = line.partition(":")
        if name.strip() != NETWORK_INTERFACE or not rest:
            continue
        fields = rest.split()
        if len(fields) < 9:
            return None
        try:
            return int(fields[0]), int(fields[8])
        except ValueError:
            return None
    return None


def build_home_media() -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    download_dir = settings.download_complete_dir
    if not download_dir.exists():
        return None, []

    download_root = download_dir.resolve()
    progress_by_path = read_video_progress()
    videos: list[dict[str, Any]] = []
    for video_path in iter_completed_video_files(download_dir):
        try:
            relative = video_path.relative_to(download_root).as_posix()
            stat = video_path.stat()
        except (OSError, ValueError):
            continue
        parent_name = video_path.parent.name if video_path.parent != download_root else None
        videos.append(
            {
                "relative": relative,
                "path": str(Path(relative)),
                "filename": video_path.name,
                "parent": parent_name,
                "mtime": stat.st_mtime,
                "thumbnail_url": thumbnail_url_for_completed_video(video_path, download_dir),
                "progress": progress_by_path.get(str(Path(relative)))
                or progress_by_path.get(relative),
            }
        )

    recently_added = build_recently_added(videos)
    continue_watching = build_continue_watching(videos)
    return continue_watching, recently_added


def build_recently_added(videos: list[dict[str, Any]]) -> list[dict[str, Any]]:
    newest = sorted(videos, key=lambda video: video["mtime"], reverse=True)[:HOME_RECENTLY_ADDED_LIMIT]
    items: list[dict[str, Any]] = []
    for video in newest:
        item = build_home_media_item(video)
        item["added_at"] = timestamp_to_iso(video["mtime"])
        items.append(item)
    return items


def build_continue_watching(videos: list[dict[str, Any]]) -> dict[str, Any] | None:
    candidates: list[dict[str, Any]] = []
    for video in videos:
        record = video["progress"]
        if not isinstance(record, dict):
            continue
        try:
            watched = float(record.get("watchedPercent", 0) or 0)
        except (TypeError, ValueError):
            watched = 0.0
        if watched != watched:
            watched = 0.0
        watched = min(max(watched, 0.0), 100.0)
        time_ms = int(record.get("timeMs", 0) or 0)
        if watched >= WATCHED_COMPLETION_PERCENT or time_ms <= 0:
            continue
        updated_at = record.get("updatedAt")
        if not isinstance(updated_at, str):
            continue
        candidates.append({"video": video, "updated_at": updated_at})

    if not candidates:
        return None

    chosen = max(candidates, key=lambda candidate: candidate["updated_at"])
    item = build_home_media_item(chosen["video"])
    item["last_watched_at"] = chosen["updated_at"]
    return item


def build_home_media_item(video: dict[str, Any]) -> dict[str, Any]:
    record = video["progress"] if isinstance(video["progress"], dict) else {}
    time_ms = int(record.get("timeMs", 0) or 0)
    duration_ms = int(record.get("durationMs", 0) or 0)
    position_seconds = time_ms // 1000
    duration_seconds = duration_ms // 1000
    metadata = parse_media_filename(video["filename"], video.get("parent"))
    artwork = tmdb_artwork_for(metadata["title"], metadata["media_type"], metadata["year"])
    return {
        "video_id": video["path"],
        "relative_path": video["path"],
        "filename": video["filename"],
        "title": metadata["title"],
        "subtitle": metadata["subtitle"],
        "year": metadata["year"],
        "position_seconds": position_seconds,
        "duration_seconds": duration_seconds,
        "progress": normalized_progress(position_seconds, duration_seconds),
        "local_thumbnail_url": video["thumbnail_url"],
        "tmdb_id": artwork["tmdb_id"] if artwork else None,
        "media_type": metadata["media_type"],
        "poster_url": artwork["poster_url"] if artwork else None,
        "backdrop_url": artwork["backdrop_url"] if artwork else None,
    }


def normalized_progress(position_seconds: int, duration_seconds: int) -> float:
    if duration_seconds <= 0:
        return 0.0
    return round(min(max(position_seconds / duration_seconds, 0.0), 1.0), 4)


def tmdb_artwork_for(title: str, media_type: str, year: int | None) -> dict[str, Any] | None:
    """Return cached TMDB artwork for a parsed media title and queue cache misses.

    Returns
    {tmdb_id, media_type, poster_url, backdrop_url} on a conservative match, or
    None while an uncached lookup runs or for a cached no-match. The API key is
    never returned to the caller.
    """
    normalized = normalize_tmdb_title(title)
    if not normalized:
        return None

    cache_key = f"{media_type}:{year or ''}:{normalized}"
    with _tmdb_jobs_lock:
        cached = _tmdb_cache.get(cache_key)
        if cached is not None and (time.monotonic() - cached[0]) < TMDB_CACHE_TTL_SECONDS:
            return cached[1]
        if cache_key in _tmdb_jobs or len(_tmdb_jobs) >= TMDB_MAX_PENDING_JOBS:
            return None
        _tmdb_jobs.add(cache_key)

    try:
        _tmdb_executor.submit(
            run_tmdb_artwork_job,
            cache_key,
            title,
            normalized,
            media_type,
            year,
        )
    except Exception as exc:
        with _tmdb_jobs_lock:
            _tmdb_jobs.discard(cache_key)
        print(f"Warning: TMDB artwork job could not be queued for {cache_key}: {exc}")
    return None


def run_tmdb_artwork_job(
    cache_key: str,
    title: str,
    normalized: str,
    media_type: str,
    year: int | None,
) -> None:
    try:
        cacheable, result = search_tmdb_artwork_result(title, normalized, media_type, year)
        if cacheable:
            with _tmdb_jobs_lock:
                _tmdb_cache[cache_key] = (time.monotonic(), result)
    except Exception as exc:
        print(f"Warning: TMDB artwork job failed for {cache_key}: {exc}")
    finally:
        with _tmdb_jobs_lock:
            _tmdb_jobs.discard(cache_key)


def normalize_tmdb_title(title: str) -> str:
    """Lowercase, strip punctuation, and collapse whitespace for conservative
    title matching (so "Sector 36" and "sector  36!" compare equal)."""
    folded = unicodedata.normalize("NFKD", title or "")
    stripped = re.sub(r"[^\w\s]", " ", folded.lower())
    return re.sub(r"\s+", " ", stripped).strip()


def search_tmdb_artwork(
    title: str, normalized: str, media_type: str, year: int | None
) -> dict[str, Any] | None:
    _, result = search_tmdb_artwork_result(title, normalized, media_type, year)
    return result


def search_tmdb_artwork_result(
    title: str,
    normalized: str,
    media_type: str,
    year: int | None,
) -> tuple[bool, dict[str, Any] | None]:
    api_key = os.environ.get("TMDB_API_KEY")
    if not api_key:
        return True, None

    # Series/episodes search the show title against /search/tv; movies against
    # /search/movie. The parser already strips episode info from the title.
    path = "/search/tv" if media_type == "tv" else "/search/movie"
    params: dict[str, Any] = {"api_key": api_key, "query": title, "include_adult": "false"}
    if year:
        params["first_air_date_year" if media_type == "tv" else "year"] = year

    try:
        response = requests.get(
            f"{TMDB_API_BASE_URL}{path}",
            params=params,
            headers={"accept": "application/json", "user-agent": "CloudBox Home"},
            timeout=TMDB_REQUEST_TIMEOUT_SECONDS,
        )
        if response.status_code != 200:
            return False, None
        results = response.json().get("results")
    except (RequestException, ValueError):
        return False, None

    if not isinstance(results, list):
        return False, None

    match = pick_tmdb_match(results, normalized, media_type, year)
    if match is None:
        return True, None

    poster_path = match.get("poster_path")
    backdrop_path = match.get("backdrop_path")
    return (
        True,
        {
            "tmdb_id": match.get("id"),
            "media_type": media_type,
            "poster_url": f"{TMDB_POSTER_BASE_URL}{poster_path}" if poster_path else None,
            "backdrop_url": f"{TMDB_BACKDROP_BASE_URL}{backdrop_path}" if backdrop_path else None,
        },
    )


def pick_tmdb_match(
    results: list[Any], normalized: str, media_type: str, year: int | None
) -> dict[str, Any] | None:
    """Conservatively choose a TMDB result: require a normalized-title match, and
    when a year is known require the result's release year to match. Rejects
    weak/conflicting candidates by returning None rather than guessing."""
    year_field = "first_air_date" if media_type == "tv" else "release_date"
    title_field = "name" if media_type == "tv" else "title"

    for raw in results:
        if not isinstance(raw, dict):
            continue
        candidate_title = raw.get(title_field) or raw.get("original_name") or raw.get("original_title") or ""
        if normalize_tmdb_title(candidate_title) != normalized:
            continue
        if year is not None:
            date_value = raw.get(year_field) or ""
            candidate_year = date_value[:4] if isinstance(date_value, str) and len(date_value) >= 4 else ""
            if candidate_year and candidate_year != str(year):
                continue
        return raw
    return None


def parse_media_filename(filename: str, parent: str | None = None) -> dict[str, Any]:
    stem = Path(filename).stem
    cleaned = re.sub(r"[._]+", " ", stem)

    year, year_match = detect_media_year(cleaned)
    tv_match = detect_tv_episode(cleaned)
    subtitle: str | None = None
    media_type = "movie"
    if tv_match:
        media_type = "tv"
        subtitle = f"S{int(tv_match.group(1)):02d}E{int(tv_match.group(2)):02d}"

    title = clean_home_media_title(cleaned, tv_match, year_match)

    # Episode filenames often lack the show title/year; the parent release folder
    # carries it. Fall back there without touching filename/relative_path identity.
    if parent and (not title or year is None):
        parent_cleaned = re.sub(r"[._]+", " ", parent)
        parent_year, parent_year_match = detect_media_year(parent_cleaned)
        if not title:
            title = clean_home_media_title(parent_cleaned, detect_tv_episode(parent_cleaned), parent_year_match)
        if year is None:
            year = parent_year

    return {"title": title or stem, "subtitle": subtitle, "year": year, "media_type": media_type}


def detect_media_year(text: str) -> tuple[int | None, Any]:
    match = re.search(r"\b(19\d{2}|20\d{2})\b", text)
    return (int(match.group(1)) if match else None), match


def detect_tv_episode(text: str) -> Any:
    return re.search(r"\bS(\d{1,2})\s?E(\d{1,2})\b", text, re.IGNORECASE) or re.search(
        r"\b(\d{1,2})x(\d{2})\b", text
    )


def clean_home_media_title(cleaned: str, tv_match: Any, year_match: Any) -> str:
    cut = len(cleaned)
    if tv_match:
        cut = min(cut, tv_match.start())
    if year_match:
        cut = min(cut, year_match.start())
    title = cleaned[:cut]

    junk = re.compile(
        r"\b(720p|1080p|2160p|480p|web[\s-]?dl|webrip|bluray|brrip|hdrip|dvdrip|x264|x265|"
        r"h\.?264|h\.?265|hevc|aac|ac3|dts|ddp?5\.?1|10bit|hdr|remux)\b.*",
        re.IGNORECASE,
    )
    title = junk.sub("", title)
    title = re.sub(r"\s+", " ", title).strip()
    return strip_unbalanced_punctuation(title)


def strip_unbalanced_punctuation(title: str) -> str:
    # Release-tag removal can sever an opening bracket from its partner
    # ("Sector 36 (2024)..." -> "Sector 36 ("). Drop trailing brackets/quotes
    # left without a match; keep balanced punctuation inside real titles.
    openers = {")": "(", "]": "[", "}": "{"}
    while title:
        last = title[-1]
        if last in "([{\"'":
            title = title[:-1].rstrip(" -–—")
            continue
        if last in openers and title.count(openers[last]) > title.count(last):
            title = title[:-1].rstrip(" -–—")
            continue
        break
    return title.strip(" -–—")


@app.post("/api/convert-markdown")
async def convert_markdown(file: UploadFile = File(...)) -> dict[str, str]:
    temp_path: Path | None = None
    worker_owns_temp_path = False
    size = 0
    try:
        filename = Path(file.filename or "").name
        extension = Path(filename).suffix.lower()
        if extension not in MARKDOWN_ALLOWED_EXTENSIONS:
            raise HTTPException(status_code=400, detail="Unsupported file type.")

        with tempfile.NamedTemporaryFile(
            delete=False,
            prefix=MARKDOWN_TEMP_PREFIX,
            suffix=extension,
        ) as temp_file:
            temp_path = Path(temp_file.name)
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > MARKDOWN_MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail="File is too large.")
                temp_file.write(chunk)

        if size == 0:
            raise HTTPException(status_code=422, detail="Markdown conversion produced no content.")

        conversion_task = asyncio.create_task(
            asyncio.to_thread(convert_local_upload_to_markdown, temp_path, extension)
        )
        retain_markdown_conversion_task(conversion_task)
        worker_owns_temp_path = True
        markdown = await asyncio.wait_for(
            asyncio.shield(conversion_task),
            timeout=MARKDOWN_CONVERSION_TIMEOUT_SECONDS,
        )
        return {
            "filename": filename,
            "extension": extension,
            "markdown": validate_local_markdown_output(markdown),
            "conversion_mode": "local",
        }
    except asyncio.TimeoutError as exc:
        raise HTTPException(status_code=504, detail="Markdown conversion timed out.") from exc
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Markdown conversion failed.") from exc
    finally:
        if temp_path is not None and not worker_owns_temp_path:
            remove_markdown_temp_file(temp_path)
        with suppress(Exception):
            file.file.close()


@app.post("/api/convert-markdown-url")
async def convert_markdown_url(payload: ConvertMarkdownURLRequest) -> dict[str, str]:
    url = normalize_public_url(payload.url)
    try:
        html = await asyncio.wait_for(
            asyncio.to_thread(download_public_html, url),
            timeout=MARKDOWN_CONVERSION_TIMEOUT_SECONDS,
        )
        markdown = await asyncio.wait_for(
            asyncio.to_thread(convert_html_bytes_to_markdown, html, url),
            timeout=MARKDOWN_CONVERSION_TIMEOUT_SECONDS,
        )
        return {
            "url": url,
            "markdown": clean_markdown_output(markdown),
            "conversion_mode": "url",
        }
    except asyncio.TimeoutError as exc:
        raise HTTPException(status_code=504, detail="URL download or Markdown conversion timed out.") from exc
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=422, detail="URL Markdown conversion failed.") from exc


def convert_local_upload_to_markdown(path: Path, extension: str) -> Any:
    try:
        converter = convert_local_image_to_markdown if extension in MARKDOWN_IMAGE_EXTENSIONS else convert_local_markdown_file
        return converter(path)
    finally:
        remove_markdown_temp_file(path)


def retain_markdown_conversion_task(task: asyncio.Task[Any]) -> None:
    markdown_conversion_tasks.add(task)

    def finish(completed_task: asyncio.Task[Any]) -> None:
        markdown_conversion_tasks.discard(completed_task)
        if not completed_task.cancelled():
            with suppress(Exception):
                completed_task.result()

    task.add_done_callback(finish)


def remove_markdown_temp_file(path: Path) -> None:
    try:
        temp_root = Path(tempfile.gettempdir()).resolve()
        resolved_path = path.resolve()
        if resolved_path.parent != temp_root or not resolved_path.name.startswith(MARKDOWN_TEMP_PREFIX):
            return
        resolved_path.unlink(missing_ok=True)
    except (OSError, RuntimeError):
        return


def validate_local_markdown_output(markdown: Any) -> str:
    if not isinstance(markdown, str):
        raise HTTPException(status_code=422, detail="Markdown conversion produced no content.")
    cleaned = clean_markdown_output(markdown)
    if not cleaned.strip():
        raise HTTPException(status_code=422, detail="Markdown conversion produced no content.")
    return cleaned


def convert_local_markdown_file(path: Path) -> Any:
    result = MarkItDown(enable_plugins=False).convert_local(path)
    markdown = getattr(result, "text_content", None)
    if markdown is None:
        markdown = getattr(result, "markdown", None)
    return markdown


def normalize_public_url(raw_url: str) -> str:
    url = raw_url.strip()
    if not url:
        raise HTTPException(status_code=400, detail="URL is required.")

    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
        raise HTTPException(status_code=400, detail="Only valid http:// and https:// URLs are accepted.")

    reject_private_url(parsed)
    return url


def reject_private_url(parsed_url: Any) -> None:
    hostname = (parsed_url.hostname or "").strip().lower().rstrip(".")
    if not hostname:
        raise HTTPException(status_code=400, detail="URL host is required.")
    if hostname == "localhost" or hostname.endswith((".localhost", ".local", ".internal")):
        raise HTTPException(status_code=400, detail="Private or internal URLs are not allowed.")
    if "." not in hostname and not hostname.replace(":", "").replace("[", "").replace("]", "").isdigit():
        raise HTTPException(status_code=400, detail="Private or internal URLs are not allowed.")

    try:
        ip_addresses = [ipaddress.ip_address(hostname)]
    except ValueError:
        try:
            addr_info = socket.getaddrinfo(hostname, parsed_url.port or default_port(parsed_url.scheme), type=socket.SOCK_STREAM)
        except socket.gaierror as exc:
            raise HTTPException(status_code=400, detail="URL host could not be resolved.") from exc
        ip_addresses = list({ipaddress.ip_address(item[4][0]) for item in addr_info})

    if not ip_addresses or any(is_blocked_ip(address) for address in ip_addresses):
        raise HTTPException(status_code=400, detail="Private or internal URLs are not allowed.")


def default_port(scheme: str) -> int:
    return 443 if scheme == "https" else 80


def is_blocked_ip(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    return (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_reserved
        or address.is_unspecified
    )


def reject_private_response_peer(response: requests.Response) -> None:
    connection = getattr(response.raw, "connection", None)
    peer_socket = getattr(connection, "sock", None)
    if peer_socket is None:
        original_response = getattr(response.raw, "_fp", None)
        buffered_reader = getattr(original_response, "fp", None)
        socket_io = getattr(buffered_reader, "raw", None)
        peer_socket = getattr(socket_io, "_sock", None)

    try:
        peer = peer_socket.getpeername()
        peer_address = ipaddress.ip_address(peer[0])
    except (AttributeError, IndexError, OSError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="Private or internal URLs are not allowed.") from exc

    if is_blocked_ip(peer_address):
        raise HTTPException(status_code=400, detail="Private or internal URLs are not allowed.")


def download_public_html(url: str) -> bytes:
    session = requests.Session()
    current_url = url
    for _ in range(MARKDOWN_URL_MAX_REDIRECTS + 1):
        try:
            response = session.get(
                current_url,
                timeout=MARKDOWN_URL_TIMEOUT_SECONDS,
                stream=True,
                allow_redirects=False,
                headers={"User-Agent": "CloudBox Markdown Converter/1.0"},
            )
        except requests.Timeout as exc:
            raise HTTPException(status_code=504, detail="URL request timed out.") from exc
        except RequestException as exc:
            raise HTTPException(status_code=502, detail="URL is unreachable.") from exc

        try:
            reject_private_response_peer(response)

            if response.is_redirect:
                location = response.headers.get("Location")
                if not location:
                    raise HTTPException(status_code=502, detail="URL redirect is invalid.")
                current_url = normalize_public_url(urljoin(current_url, location))
                continue

            if response.status_code >= 400:
                raise HTTPException(status_code=502, detail="URL returned an error.")

            content_type = response.headers.get("content-type", "").lower()
            if content_type and not any(kind in content_type for kind in ("text/html", "application/xhtml+xml")):
                raise HTTPException(status_code=415, detail="URL content is not a supported HTML page.")

            content_length = response.headers.get("content-length")
            if content_length:
                with suppress(ValueError):
                    if int(content_length) > MARKDOWN_URL_MAX_BYTES:
                        raise HTTPException(status_code=413, detail="URL content is too large.")

            chunks: list[bytes] = []
            size = 0
            try:
                for chunk in response.iter_content(chunk_size=64 * 1024):
                    if not chunk:
                        continue
                    size += len(chunk)
                    if size > MARKDOWN_URL_MAX_BYTES:
                        raise HTTPException(status_code=413, detail="URL content is too large.")
                    chunks.append(chunk)
            except RequestException as exc:
                raise HTTPException(status_code=502, detail="URL download failed.") from exc
            return b"".join(chunks)
        finally:
            response.close()

    raise HTTPException(status_code=502, detail="URL has too many redirects.")


def convert_html_bytes_to_markdown(html: bytes, url: str) -> str:
    result = MarkItDown(enable_plugins=False).convert_stream(BytesIO(html), file_extension=".html", url=url)
    markdown = getattr(result, "text_content", None)
    if markdown is None:
        markdown = getattr(result, "markdown", "")
    markdown_text = str(markdown)
    if not markdown_text.strip():
        raise HTTPException(status_code=422, detail="URL Markdown conversion produced no content.")
    return markdown_text


def convert_local_image_to_markdown(path: Path) -> str:
    if shutil.which("tesseract") is None:
        raise HTTPException(status_code=503, detail="OCR engine is not installed on this server.")

    try:
        import pytesseract
        from PIL import Image, ImageEnhance, ImageOps
    except ImportError as exc:
        raise HTTPException(status_code=503, detail="OCR support is not installed on this server.") from exc

    processed_path: Path | None = None
    try:
        with Image.open(path) as image:
            processed_image = preprocess_ocr_image(image, Image, ImageEnhance, ImageOps)
            with tempfile.NamedTemporaryFile(delete=False, suffix=".png") as temp_file:
                processed_path = Path(temp_file.name)
            processed_image.save(processed_path, format="PNG", optimize=True)

        languages = set(pytesseract.get_languages(config=""))
        lang = "+".join(language for language in ("eng", "jpn") if language in languages) or None
        config = "--oem 3 --psm 6 -c preserve_interword_spaces=1"
        text = pytesseract.image_to_string(str(processed_path), lang=lang, config=config)
        return clean_ocr_markdown_output(text)
    finally:
        if processed_path is not None:
            with suppress(OSError):
                processed_path.unlink(missing_ok=True)


def preprocess_ocr_image(image: Any, image_module: Any, image_enhance: Any, image_ops: Any) -> Any:
    image = image_ops.exif_transpose(image)
    if image.mode in {"RGBA", "LA"}:
        background = image_module.new("RGB", image.size, "white")
        background.paste(image, mask=image.getchannel("A"))
        image = background
    elif image.mode != "RGB":
        image = image.convert("RGB")

    max_dimension = max(image.size)
    if max_dimension < 1600:
        scale = 1600 / max_dimension
        size = (int(image.width * scale), int(image.height * scale))
        image = image.resize(size, image_module.Resampling.LANCZOS)

    image = image.convert("L")
    image = image_ops.autocontrast(image)
    image = image_enhance.Contrast(image).enhance(1.35)
    return image_enhance.Sharpness(image).enhance(1.25)


def clean_ocr_markdown_output(markdown: str) -> str:
    raw_lines = markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    lines: list[str] = []
    for raw_line in raw_lines:
        line = re.sub(r"[ \t]+", " ", raw_line.strip())
        if line and not is_ocr_garbage_line(line):
            lines.append(line)
        elif lines and lines[-1] != "":
            lines.append("")

    if not any(lines):
        return ""

    blocks: list[str] = []
    paragraph: list[str] = []

    def flush_paragraph() -> None:
        if not paragraph:
            return
        blocks.append(join_ocr_paragraph(paragraph))
        paragraph.clear()

    seen_content = False
    content_lines = [line for line in lines if line]
    first_content = content_lines[0] if content_lines else ""

    for index, line in enumerate(lines):
        if not line:
            flush_paragraph()
            continue

        next_line = next((candidate for candidate in lines[index + 1 :] if candidate), "")
        bullet_text = ocr_bullet_text(line)
        if bullet_text is not None:
            flush_paragraph()
            blocks.append(f"- {bullet_text}")
            seen_content = True
            continue

        if is_ocr_numbered_line(line):
            flush_paragraph()
            blocks.append(line)
            seen_content = True
            continue

        if not seen_content and line == first_content and is_ocr_title_line(line, next_line):
            flush_paragraph()
            blocks.append(f"# {line.rstrip(':')}")
            seen_content = True
            continue

        if is_ocr_section_line(line, next_line):
            flush_paragraph()
            blocks.append(f"## {line.rstrip(':')}")
            seen_content = True
            continue

        paragraph.append(line)
        seen_content = True

    flush_paragraph()
    return re.sub(r"\n{3,}", "\n\n", "\n\n".join(block for block in blocks if block).strip())


def is_ocr_garbage_line(line: str) -> bool:
    if re.search(r"[A-Za-z0-9\u3040-\u30ff\u3400-\u9fff]", line):
        return False
    if re.search(r"[¥$€£:/@.-]", line):
        return False
    return len(line) <= 6 or bool(re.fullmatch(r"([^\w\s])\1{2,}", line))


def ocr_bullet_text(line: str) -> str | None:
    match = re.match(r"^([*+\-•‣・●○▪▫]|[oO])\s+(.+)$", line)
    if not match:
        return None
    text = match.group(2).strip()
    return text or None


def is_ocr_numbered_line(line: str) -> bool:
    return bool(re.match(r"^\d{1,3}[\.)]\s+\S+", line))


def is_ocr_title_line(line: str, next_line: str) -> bool:
    if not next_line or is_ocr_data_line(line) or ocr_bullet_text(line) is not None:
        return False
    if len(line) > 80 or re.search(r"[.!?。！？,，、;；]$", line):
        return False
    if has_cjk(line):
        return len(line) <= 40
    words = re.findall(r"[A-Za-z]+", line)
    if not words or len(words) > 12:
        return False
    uppercase_words = sum(1 for word in words if word.isupper())
    title_words = sum(1 for word in words if word[:1].isupper())
    return uppercase_words == len(words) or title_words >= max(1, len(words) - 1)


def is_ocr_section_line(line: str, next_line: str) -> bool:
    if not next_line or is_ocr_data_line(line) or ocr_bullet_text(line) is not None or is_ocr_numbered_line(line):
        return False
    if len(line) > 56 or re.search(r"[.!?。！？,，、;；]$", line):
        return False
    if line.endswith(":"):
        return True
    if has_cjk(line):
        return len(line) <= 24
    words = re.findall(r"[A-Za-z]+", line)
    if not words or len(words) > 8:
        return False
    uppercase_words = sum(1 for word in words if word.isupper())
    title_words = sum(1 for word in words if word[:1].isupper())
    return uppercase_words == len(words) or title_words >= max(1, len(words) - 1)


def is_ocr_data_line(line: str) -> bool:
    return bool(
        re.search(r"https?://|www\.|[\w.+-]+@[\w.-]+|[@¥$€£]|\d{1,2}[:/.-]\d{1,2}|\d{2,}", line)
    )


def join_ocr_paragraph(lines: list[str]) -> str:
    joined: list[str] = []
    for line in lines:
        if joined and should_join_ocr_lines(joined[-1], line):
            joined[-1] = join_ocr_lines(joined[-1], line)
        else:
            joined.append(line)
    return "\n".join(joined)


def should_join_ocr_lines(previous: str, current: str) -> bool:
    if not previous or not current:
        return False
    if previous.startswith("#") or current.startswith("#"):
        return False
    if ocr_bullet_text(previous) is not None or ocr_bullet_text(current) is not None:
        return False
    if is_ocr_numbered_line(previous) or is_ocr_numbered_line(current):
        return False
    if re.search(r"[.!?。！？:：]$", previous):
        return False
    if is_ocr_data_line(previous) or is_ocr_data_line(current):
        return False
    return bool(
        re.search(r"[,，、;；\-]$", previous)
        or re.match(r"^[a-z)\]}]", current)
        or (has_cjk(previous[-1:]) and has_cjk(current[:1]))
    )


def join_ocr_lines(previous: str, current: str) -> str:
    separator = "" if has_cjk(previous[-1:]) and has_cjk(current[:1]) else " "
    return previous.rstrip() + separator + current.lstrip()


def has_cjk(text: str) -> bool:
    return bool(re.search(r"[\u3040-\u30ff\u3400-\u9fff]", text))


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
    result: dict[str, Any] = {
        "torrent_hash": torrent_hash,
        "torrent_name": str(torrent.get("name", "")) if torrent else None,
        "qbittorrent_delete_result": None,
        "candidate_paths_checked": [],
        "deleted_file_paths": [],
        "deleted_folder_paths": [],
        "warnings": [] if torrent else ["Torrent was not found before delete."],
    }

    torrent_files: list[dict[str, Any]] = []
    if torrent:
        try:
            torrent_files = run_qb_action("get_files", torrent_hash)
        except HTTPException as exc:
            result["warnings"].append(
                f"Could not verify qBittorrent file paths before delete: {exc.detail}"
            )

    candidates, content_root = build_delete_candidates(torrent, torrent_files)
    result["candidate_paths_checked"] = [str(path) for path in candidates]
    if torrent and not candidates:
        result["warnings"].append("No content-verified completed files were found.")

    qbittorrent_deleted = False
    try:
        result["qbittorrent_delete_result"] = run_qb_action(
            "delete",
            torrent_hash,
            delete_files=False,
        )
        qbittorrent_deleted = True
    except HTTPException as exc:
        result["warnings"].append(f"qBittorrent delete failed: {exc.detail}")

    delete_completed_candidates(candidates, result)
    remove_empty_content_directories(candidates, content_root, result)
    set_delete_status(result, qbittorrent_deleted=qbittorrent_deleted)
    return result


def find_torrent(torrent_hash: str) -> dict[str, Any] | None:
    for torrent in run_qb_action("list_torrents"):
        if str(torrent.get("hash", "")) == torrent_hash:
            return torrent
    return None


def build_delete_candidates(
    torrent: dict[str, Any] | None,
    torrent_files: list[dict[str, Any]],
) -> tuple[list[Path], Path | None]:
    if torrent is None or not torrent_files:
        return [], None

    download_root = settings.download_complete_dir.resolve()
    content_path = str(torrent.get("content_path") or "").strip()
    save_path = str(torrent.get("save_path") or "").strip()
    if not content_path or not save_path:
        return [], None

    try:
        content_root = resolve_safe_download_target(Path(content_path), download_root)
    except ValueError:
        return [], None

    safe_candidates: list[Path] = []
    seen: set[Path] = set()
    for torrent_file in torrent_files:
        relative_name = Path(str(torrent_file.get("name") or "").strip())
        if (
            not relative_name.parts
            or relative_name.is_absolute()
            or ".." in relative_name.parts
        ):
            continue

        try:
            safe = resolve_safe_download_target(Path(save_path) / relative_name, download_root)
        except ValueError:
            continue

        if safe != content_root and not safe.is_relative_to(content_root):
            continue
        if safe not in seen:
            seen.add(safe)
            safe_candidates.append(safe)

    return safe_candidates, content_root


def delete_completed_candidates(candidates: list[Path], result: dict[str, Any]) -> None:
    deleted_video_paths: set[str] = set()
    for candidate in candidates:
        deleted_video_paths.update(delete_file_with_sidecars(candidate, result))
    remove_video_progress(deleted_video_paths)


def delete_file_with_sidecars(file_path: Path, result: dict[str, Any]) -> set[str]:
    download_root = settings.download_complete_dir.resolve()
    deleted_video_paths: set[str] = set()
    try:
        primary_path = resolve_safe_download_target(file_path, download_root)
    except ValueError:
        primary_path = None
    paths: list[Path] = [file_path]
    if is_video_file(file_path):
        for suffix in (".srt", ".vtt"):
            subtitle_path = file_path.with_suffix(suffix)
            paths.extend(
                [
                    subtitle_path,
                    subtitle_backup_path(subtitle_path),
                    subtitle_path.with_name(f".{subtitle_path.name}.tmp"),
                ]
            )
        paths.extend(thumbnail_cache_paths_for_video(file_path, download_root))

    for path in paths:
        try:
            safe_path = resolve_safe_download_target(path, download_root)
        except ValueError:
            result["warnings"].append(f"Refused to delete unsafe associated path: {path}")
            continue

        try:
            safe_path.unlink()
            result["deleted_file_paths"].append(str(safe_path))
            if safe_path == primary_path and is_video_file(safe_path):
                deleted_video_paths.add(safe_path.relative_to(download_root).as_posix())
        except FileNotFoundError:
            continue
        except OSError as exc:
            result["warnings"].append(f"Failed to delete {safe_path}: {exc}")
    return deleted_video_paths


def thumbnail_cache_paths_for_video(video_path: Path, download_root: Path) -> list[Path]:
    try:
        safe_video = resolve_safe_download_target(video_path, download_root)
        if not safe_video.is_file() or not is_video_file(safe_video):
            return []
        relative = safe_video.relative_to(download_root).as_posix()
        stat = safe_video.stat()
    except (OSError, ValueError):
        return []

    cache_key = hashlib.sha256(
        f"{THUMBNAIL_CACHE_VERSION}:{relative}:{stat.st_size}:{stat.st_mtime_ns}".encode("utf-8")
    ).hexdigest()
    thumbnail_path = download_root / THUMBNAIL_CACHE_DIR_NAME / (
        f"{THUMBNAIL_CACHE_VERSION}-{cache_key}.jpg"
    )
    paths = [thumbnail_path]
    cache_dir = thumbnail_path.parent
    if cache_dir.is_dir():
        paths.extend(cache_dir.glob(f"{thumbnail_path.stem}.candidate-*.jpg"))
    return paths


def remove_empty_content_directories(
    candidates: list[Path],
    content_root: Path | None,
    result: dict[str, Any],
) -> None:
    download_root = settings.download_complete_dir.resolve()
    if content_root is None or content_root == download_root:
        return

    directories: set[Path] = set()
    for candidate in candidates:
        directory = candidate.parent
        while directory == content_root or directory.is_relative_to(content_root):
            directories.add(directory)
            if directory == content_root:
                break
            directory = directory.parent

    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        try:
            directory.rmdir()
            result["deleted_folder_paths"].append(str(directory))
        except FileNotFoundError:
            continue
        except OSError:
            # Non-empty directories are intentionally preserved. Other failures
            # matter only when an empty directory should have been removable.
            try:
                if directory.is_dir() and any(directory.iterdir()):
                    continue
            except OSError:
                pass
            result["warnings"].append(f"Failed to remove empty folder {directory}.")


def set_delete_status(result: dict[str, Any], *, qbittorrent_deleted: bool) -> None:
    disk_deleted = bool(result["deleted_file_paths"] or result["deleted_folder_paths"])
    if not result["warnings"]:
        status = "deleted"
    elif qbittorrent_deleted or disk_deleted:
        status = "partial"
    else:
        status = "failed"
    result["status"] = status
    result["partial_success"] = status == "partial"


@app.delete("/api/completed-files")
def delete_completed_item(path: str = Query(...)) -> dict[str, Any]:
    target = resolve_completed_delete_target(path)
    result: dict[str, Any] = {
        "torrent_hash": None,
        "torrent_name": None,
        "qbittorrent_delete_result": None,
        "candidate_paths_checked": [str(target)],
        "deleted_file_paths": [],
        "deleted_folder_paths": [],
        "warnings": [],
    }

    if target.is_dir():
        delete_completed_folder(target, result)
    else:
        remove_video_progress(delete_file_with_sidecars(target, result))

    set_delete_status(result, qbittorrent_deleted=False)
    return result


def resolve_completed_delete_target(relative_path: str) -> Path:
    raw_path = relative_path.strip()
    requested = Path(raw_path)
    raw_parts = [part for part in re.split(r"[\\/]+", raw_path) if part]
    if (
        not raw_path
        or requested.is_absolute()
        or raw_path.startswith(("/", "\\"))
        or re.match(r"^[A-Za-z]:[\\/]", raw_path)
        or ".." in raw_parts
    ):
        raise HTTPException(status_code=400, detail="Invalid completed-file path.")

    download_root = settings.download_complete_dir.resolve()
    try:
        target = resolve_safe_download_target(download_root / requested, download_root)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid completed-file path.") from exc

    if not target.exists():
        raise HTTPException(status_code=404, detail="Completed file or folder not found.")
    if THUMBNAIL_CACHE_DIR_NAME in target.relative_to(download_root).parts:
        raise HTTPException(status_code=400, detail="Invalid completed-file path.")
    if target.is_file():
        if not is_visible_completed_file(target, download_root):
            raise HTTPException(status_code=400, detail="Path is not a listed completed file.")
        return target
    if target.is_dir() and completed_folder_is_listed(target, download_root):
        return target
    raise HTTPException(status_code=400, detail="Path is not a listed completed item.")


def completed_folder_is_listed(folder: Path, download_root: Path) -> bool:
    for file_path in folder.rglob("*"):
        if file_path.is_file() and is_visible_completed_file(file_path, download_root):
            return True
    return False


def delete_completed_folder(folder: Path, result: dict[str, Any]) -> None:
    download_root = settings.download_complete_dir.resolve()
    original_files = [path for path in folder.rglob("*") if path.is_file()]
    video_paths = list(iter_completed_video_files(folder))
    progress_paths = {
        video_path.relative_to(download_root).as_posix()
        for video_path in video_paths
    }
    for video_path in video_paths:
        for thumbnail_path in thumbnail_cache_paths_for_video(video_path, download_root):
            try:
                safe_thumbnail = resolve_safe_download_target(thumbnail_path, download_root)
                safe_thumbnail.unlink()
                result["deleted_file_paths"].append(str(safe_thumbnail))
            except FileNotFoundError:
                continue
            except ValueError:
                result["warnings"].append(
                    f"Refused to delete unsafe thumbnail path: {thumbnail_path}"
                )
            except OSError as exc:
                result["warnings"].append(f"Failed to delete {thumbnail_path}: {exc}")

    try:
        shutil.rmtree(folder)
        result["deleted_folder_paths"].append(str(folder))
        remove_video_progress(progress_paths)
    except OSError as exc:
        result["warnings"].append(f"Failed to delete {folder}: {exc}")
        for original_file in original_files:
            if not original_file.exists() and str(original_file) not in result["deleted_file_paths"]:
                result["deleted_file_paths"].append(str(original_file))


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
        schedule_video_thumbnail(video_path, download_dir)


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

    cache_info = video_thumbnail_cache_info(file_path, download_dir)
    if cache_info is None:
        return None
    video_path, thumbnail_path, _, _ = cache_info
    if not is_valid_thumbnail(thumbnail_path):
        schedule_video_thumbnail(video_path, download_dir)
        return None

    try:
        relative = thumbnail_path.relative_to(download_dir.resolve()).as_posix()
    except ValueError:
        return None
    return f"{settings.stream_base_url}/{quote(relative)}?v={THUMBNAIL_CACHE_VERSION}"


def video_thumbnail_cache_info(
    file_path: Path,
    download_dir: Path,
) -> tuple[Path, Path, bytes, str] | None:
    download_root = download_dir.resolve()

    try:
        video_path = resolve_safe_download_target(file_path, download_root)
        if not video_path.is_file() or not is_video_file(video_path):
            return None
        relative = video_path.relative_to(download_root).as_posix()
        stat = video_path.stat()
    except (OSError, ValueError):
        return None

    path_seed = hashlib.sha256(relative.encode("utf-8")).digest()
    cache_key = hashlib.sha256(
        f"{THUMBNAIL_CACHE_VERSION}:{relative}:{stat.st_size}:{stat.st_mtime_ns}".encode("utf-8")
    ).hexdigest()

    try:
        thumbnail_path = resolve_safe_download_target(
            download_root
            / THUMBNAIL_CACHE_DIR_NAME
            / f"{THUMBNAIL_CACHE_VERSION}-{cache_key}.jpg",
            download_root,
        )
    except ValueError:
        return None
    return video_path, thumbnail_path, path_seed, relative


def schedule_video_thumbnail(file_path: Path, download_dir: Path) -> None:
    cache_info = video_thumbnail_cache_info(file_path, download_dir)
    if cache_info is None:
        return
    video_path, thumbnail_path, _, _ = cache_info
    if is_valid_thumbnail(thumbnail_path):
        return

    with _thumbnail_jobs_lock:
        if video_path in _thumbnail_jobs:
            return
        if len(_thumbnail_jobs) >= THUMBNAIL_MAX_PENDING_JOBS:
            return
        _thumbnail_jobs.add(video_path)

    try:
        _thumbnail_executor.submit(
            run_video_thumbnail_job,
            video_path,
            download_dir.resolve(),
        )
    except Exception as exc:
        with _thumbnail_jobs_lock:
            _thumbnail_jobs.discard(video_path)
        print(f"Warning: thumbnail job could not be queued for {video_path}: {exc}")


def run_video_thumbnail_job(video_path: Path, download_dir: Path) -> None:
    try:
        ensure_video_thumbnail(video_path, download_dir)
    except Exception as exc:
        print(f"Warning: thumbnail job failed for {video_path}: {exc}")
    finally:
        with _thumbnail_jobs_lock:
            _thumbnail_jobs.discard(video_path)


def ensure_video_thumbnail(file_path: Path, download_dir: Path) -> Path | None:
    cache_info = video_thumbnail_cache_info(file_path, download_dir)
    if cache_info is None:
        return None
    video_path, thumbnail_path, path_seed, relative = cache_info

    if is_valid_thumbnail(thumbnail_path):
        return thumbnail_path
    if shutil.which("ffmpeg") is None:
        return None
    if thumbnail_path.exists():
        try:
            thumbnail_path.unlink()
        except OSError:
            return None

    cache_dir = thumbnail_path.parent
    try:
        cache_dir.mkdir(exist_ok=True)
    except OSError:
        return None

    duration = probe_video_duration(video_path)
    candidates: list[tuple[float, Path]] = []
    try:
        for index, timestamp in enumerate(thumbnail_timestamps(duration, path_seed)):
            candidate_path = thumbnail_path.with_name(f"{thumbnail_path.stem}.candidate-{index}.jpg")
            candidate_path.unlink(missing_ok=True)
            if not extract_video_thumbnail(video_path, candidate_path, timestamp):
                continue

            score = score_thumbnail_candidate(candidate_path)
            if score is not None:
                candidates.append((score, candidate_path))

        if candidates:
            _, best_path = max(candidates, key=lambda candidate: candidate[0])
            best_path.replace(thumbnail_path)
            return thumbnail_path
    finally:
        for _, candidate_path in candidates:
            if candidate_path != thumbnail_path:
                candidate_path.unlink(missing_ok=True)
        for candidate_path in cache_dir.glob(f"{thumbnail_path.stem}.candidate-*.jpg"):
            candidate_path.unlink(missing_ok=True)

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


def probe_video_duration(video_path: Path) -> float | None:
    if shutil.which("ffprobe") is None:
        return None

    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(video_path),
            ],
            capture_output=True,
            text=True,
            timeout=FFPROBE_TIMEOUT_S,
        )
        duration = float(result.stdout.strip())
        return duration if result.returncode == 0 and duration > 0 else None
    except (ValueError, subprocess.SubprocessError, OSError):
        return None


def thumbnail_timestamps(duration: float | None, path_seed: bytes) -> list[float]:
    seed_value = int.from_bytes(path_seed[:8], "big")

    if duration is None:
        base = [45.0, 75.0, 105.0, 135.0, 30.0]
        rotation = seed_value % len(base)
        return base[rotation:] + base[:rotation]

    if duration < 8:
        return [max(0.1, duration * 0.50), max(0.1, duration * 0.25)]

    fractions = [0.25, 0.35, 0.45, 0.55, 0.65, 0.75]
    rotation = seed_value % len(fractions)
    fractions = fractions[rotation:] + fractions[:rotation]
    jitter = (((seed_value >> 8) % 401) - 200) / 10000.0
    fractions = [min(0.78, max(0.23, fraction + jitter)) for fraction in fractions]

    timestamps = [min(duration - 0.5, max(0.5, duration * fraction)) for fraction in fractions]
    if duration < 20:
        timestamps.extend([duration * 0.50, duration * 0.70])
    return list(dict.fromkeys(round(timestamp, 3) for timestamp in timestamps if timestamp >= 0))


def extract_video_thumbnail(video_path: Path, thumbnail_path: Path, timestamp_seconds: float) -> bool:
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


def score_thumbnail_candidate(candidate_path: Path) -> float | None:
    try:
        result = subprocess.run(
            [
                "ffmpeg",
                "-v", "error",
                "-i", str(candidate_path),
                "-vf", "scale=64:64,format=gray",
                "-f", "rawvideo",
                "-",
            ],
            capture_output=True,
            timeout=FFMPEG_TIMEOUT_S,
        )
    except (subprocess.SubprocessError, OSError):
        return None

    pixels = result.stdout
    if result.returncode != 0 or len(pixels) != 64 * 64:
        return None

    count = len(pixels)
    mean = sum(pixels) / count
    variance = sum((pixel - mean) ** 2 for pixel in pixels) / count
    dark_ratio = sum(pixel < 32 for pixel in pixels) / count
    bright_ratio = sum(pixel > 220 for pixel in pixels) / count
    midtone_ratio = sum(48 <= pixel <= 208 for pixel in pixels) / count

    horizontal_edges = sum(
        abs(pixels[row * 64 + column] - pixels[row * 64 + column - 1])
        for row in range(64)
        for column in range(1, 64)
    )
    vertical_edges = sum(
        abs(pixels[row * 64 + column] - pixels[(row - 1) * 64 + column])
        for row in range(1, 64)
        for column in range(64)
    )
    edge_detail = (horizontal_edges + vertical_edges) / (2 * 64 * 63)

    # Reject black fades, flat/static frames, and common white-text-on-black
    # title/legal cards. The latter have a dark field, few bright pixels, and
    # sharp sparse edges but little tonal variance across most of the frame.
    if mean < 28 or variance < 180 or dark_ratio > 0.78:
        return None
    if dark_ratio > 0.58 and 0.005 < bright_ratio < 0.18 and midtone_ratio < 0.28:
        return None

    return (
        variance ** 0.5 * 2.0
        + edge_detail * 1.5
        + midtone_ratio * 45.0
        - dark_ratio * 35.0
        - bright_ratio * 12.0
    )


def organize_loose_completed_videos(download_dir: Path) -> None:
    download_root = download_dir.resolve()
    move_safety = qbittorrent_file_move_safety(download_root)
    if move_safety is None:
        return

    for file_path in sorted(download_root.iterdir()):
        try:
            if not file_path.is_file() or not is_video_file(file_path):
                continue
            if not move_safety.get(file_path.resolve(), True):
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


def qbittorrent_file_move_safety(download_root: Path) -> dict[Path, bool] | None:
    try:
        torrents = run_qb_action("list_torrents")
    except HTTPException:
        return None
    if not isinstance(torrents, list):
        return None

    move_safety: dict[Path, bool] = {}
    for torrent in torrents:
        if not isinstance(torrent, dict):
            return None
        try:
            progress = float(torrent["progress"])
            state = str(torrent["state"] or "").strip()
        except (KeyError, TypeError, ValueError):
            return None
        if not 0 <= progress <= 1 or not state:
            return None
        torrent_safe = progress >= 1 and state in QB_SAFE_TO_MOVE_STATES

        content_path = resolved_qb_path(torrent.get("content_path"))
        save_path = resolved_qb_path(torrent.get("save_path"))
        if content_path is None and save_path is None:
            return None
        content_in_root = path_is_in_root(content_path, download_root)
        save_in_root = path_is_in_root(save_path, download_root, allow_root=True)
        if not content_in_root and not save_in_root:
            continue

        torrent_hash = str(torrent.get("hash") or "").strip()
        if not torrent_hash:
            return None
        try:
            torrent_files = run_qb_action("get_files", torrent_hash)
        except HTTPException:
            return None
        if not isinstance(torrent_files, list):
            return None

        tracked_paths: dict[Path, bool] = {}
        if content_in_root and content_path is not None:
            tracked_paths[content_path] = torrent_safe
        if save_in_root and save_path is not None:
            for torrent_file in torrent_files:
                if not isinstance(torrent_file, dict):
                    return None
                try:
                    file_progress = float(torrent_file["progress"])
                except (KeyError, TypeError, ValueError):
                    return None
                if not 0 <= file_progress <= 1:
                    return None
                relative_name = Path(str(torrent_file.get("name") or "").strip())
                if (
                    not relative_name.parts
                    or relative_name.is_absolute()
                    or ".." in relative_name.parts
                ):
                    return None
                file_path = (save_path / relative_name).resolve()
                if path_is_in_root(file_path, download_root):
                    file_safe = torrent_safe and file_progress >= 1
                    tracked_paths[file_path] = tracked_paths.get(file_path, True) and file_safe

        if not tracked_paths:
            return None

        for tracked_path, path_safe in tracked_paths.items():
            move_safety[tracked_path] = move_safety.get(tracked_path, True) and path_safe

    return move_safety


def resolved_qb_path(value: Any) -> Path | None:
    raw_path = str(value or "").strip()
    return Path(raw_path).resolve() if raw_path else None


def path_is_in_root(path: Path | None, root: Path, *, allow_root: bool = False) -> bool:
    return path is not None and path.is_relative_to(root) and (allow_root or path != root)


def move_into_directory(file_path: Path, target_dir: Path, download_root: Path) -> None:
    source = resolve_safe_download_target(file_path, download_root)
    destination = resolve_safe_download_target(target_dir / file_path.name, download_root)
    if destination.exists():
        return
    shutil.move(str(source), str(destination))


@app.post("/api/video-progress")
def save_video_progress(payload: VideoProgressRequest) -> dict[str, Any]:
    time_ms = max(0, int(payload.timeMs))
    duration_ms = max(0, int(payload.durationMs))
    watched_percent = progress_percent(time_ms, duration_ms)
    updated_at = datetime.now(timezone.utc).isoformat()

    with _video_progress_lock:
        path = resolve_video_progress_path(payload.path)
        record = {
            "path": path,
            "timeMs": time_ms,
            "durationMs": duration_ms,
            "watchedPercent": watched_percent,
            "updatedAt": updated_at,
        }
        progress = read_video_progress_unlocked()
        progress[path] = record
        write_video_progress_unlocked(progress)
    return record


@app.get("/api/video-progress")
def get_video_progress() -> list[dict[str, Any]]:
    return list(read_video_progress().values())


def resolve_video_progress_path(relative_path: str) -> str:
    raw_path = relative_path.strip()
    requested = Path(raw_path)
    raw_parts = [part for part in re.split(r"[\\/]+", raw_path) if part]
    if (
        not raw_path
        or requested.is_absolute()
        or raw_path.startswith(("/", "\\"))
        or re.match(r"^[A-Za-z]:[\\/]", raw_path)
        or ".." in raw_parts
    ):
        raise HTTPException(status_code=400, detail="Invalid video progress path.")

    download_root = settings.download_complete_dir.resolve()
    try:
        target = resolve_safe_download_target(download_root / requested, download_root)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid video progress path.") from exc

    if not target.is_file():
        raise HTTPException(status_code=404, detail="Video file not found.")
    if not is_video_file(target) or not is_visible_completed_file(target, download_root):
        raise HTTPException(status_code=400, detail="Path is not a playable completed video.")
    return target.relative_to(download_root).as_posix()


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
OPENSUBTITLES_API_URL = "https://api.opensubtitles.com/api/v1"
SUBTITLE_SEARCH_MIN_CONFIDENCE = 72.0
SUBTITLE_SEARCH_TIMEOUT_S = 20
SRT_PARTIAL_MIN_BYTES = 5_000
SRT_PARTIAL_MIN_CUES = 80
SRT_LATE_FIRST_CUE_SECONDS = 10 * 60
SRT_SHORT_VIDEO_SECONDS = 20 * 60
SRT_TIMING_RE = re.compile(
    r"^\s*(\d{1,2}):([0-5]\d):([0-5]\d)(?:[,.](\d{1,3}))?\s*-->"
)


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


@app.post("/api/subtitles/search")
def search_subtitle(payload: ExtractSubtitleRequest) -> dict[str, Any]:
    try:
        video_path = resolve_completed_path(payload.path)
    except HTTPException:
        return {"status": "invalid_path"}

    srt_path = video_path.with_suffix(".srt")
    if srt_path.exists():
        existing_quality = classify_srt_quality(srt_path, video_path)
        if existing_quality == "full/usable":
            sanitize_subtitle_file(srt_path, create_backup=True)
            return {"status": "exists", "url": srt_stream_url(srt_path)}

    config = opensubtitles_config()
    if config is None:
        return {"status": "provider_not_configured"}

    metadata = detect_subtitle_metadata(video_path)
    token = opensubtitles_login(config)
    if token is None:
        return {"status": "provider_unavailable"}

    candidates = opensubtitles_search(config, token, metadata)
    if candidates is None:
        return {"status": "provider_unavailable"}
    if not candidates:
        return {"status": "not_found"}

    scored = [
        (score_subtitle_candidate(candidate, metadata), candidate)
        for candidate in candidates
    ]
    scored = [(score, candidate) for score, candidate in scored if score > 0]
    if not scored:
        return {"status": "not_found"}

    best_score, best_candidate = max(scored, key=lambda item: item[0])
    if best_score < SUBTITLE_SEARCH_MIN_CONFIDENCE:
        return {"status": "low_confidence", "score": round(best_score, 2)}

    content = opensubtitles_download(config, token, best_candidate)
    if content is None:
        return {"status": "download_failed"}
    if srt_path.exists() and classify_srt_quality(srt_path, video_path) == "full/usable":
        sanitize_subtitle_file(srt_path, create_backup=True)
        return {"status": "exists", "url": srt_stream_url(srt_path)}
    if classify_srt_quality_bytes(content, probe_video_duration(video_path)) != "full/usable":
        return {"status": "low_confidence", "score": round(best_score, 2)}
    if not save_downloaded_subtitle(content, srt_path, replace_existing_partial=True):
        return {"status": "download_failed"}

    sanitize_subtitle_file(srt_path, create_backup=True)
    return {"status": "found", "url": srt_stream_url(srt_path), "score": round(best_score, 2)}


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


def opensubtitles_config() -> dict[str, str] | None:
    config = {
        "api_key": os.getenv("OPENSUBTITLES_API_KEY", "").strip(),
        "username": os.getenv("OPENSUBTITLES_USERNAME", "").strip(),
        "password": os.getenv("OPENSUBTITLES_PASSWORD", "").strip(),
    }
    return config if all(config.values()) else None


def opensubtitles_headers(config: dict[str, str], token: str | None = None) -> dict[str, str]:
    headers = {
        "Api-Key": config["api_key"],
        "Content-Type": "application/json",
        "User-Agent": "CloudBox/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def opensubtitles_login(config: dict[str, str]) -> str | None:
    try:
        response = requests.post(
            f"{OPENSUBTITLES_API_URL}/login",
            headers=opensubtitles_headers(config),
            json={"username": config["username"], "password": config["password"]},
            timeout=SUBTITLE_SEARCH_TIMEOUT_S,
        )
        if response.status_code != 200:
            return None
        token = response.json().get("token")
        return token if isinstance(token, str) and token else None
    except (RequestException, ValueError):
        return None


def detect_subtitle_metadata(video_path: Path) -> dict[str, Any]:
    stem = video_path.stem
    parent = video_path.parent.name
    combined = f"{parent} {stem}" if parent and parent != stem else stem
    season, episode = parse_episode_numbers(combined)
    year = parse_year(combined)

    title_source = parent if season is not None and parent else stem
    title = clean_media_title(title_source)
    if not title:
        title = clean_media_title(stem)

    release_hints = release_tokens(stem)
    return {
        "title": title,
        "year": year,
        "season": season,
        "episode": episode,
        "language": "en",
        "release_hints": release_hints,
        "filename_tokens": release_tokens(stem),
        "query": clean_media_title(stem),
    }


def parse_episode_numbers(text: str) -> tuple[int | None, int | None]:
    patterns = [
        r"(?i)\bS(\d{1,2})E(\d{1,3})\b",
        r"(?i)\b(\d{1,2})x(\d{1,3})\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return int(match.group(1)), int(match.group(2))
    return None, None


def parse_year(text: str) -> int | None:
    match = re.search(r"\b(19\d{2}|20\d{2})\b", text)
    return int(match.group(1)) if match else None


def clean_media_title(text: str) -> str:
    cleaned = re.sub(r"(?i)\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b", " ", text)
    cleaned = re.sub(r"\b(19\d{2}|20\d{2})\b", " ", cleaned)
    cleaned = re.sub(
        r"(?i)\b(720p|1080p|2160p|480p|bluray|blu-ray|webrip|web-dl|webdl|hdtv|x264|x265|h264|h265|hevc|aac|dts|hdr|dv|proper|repack|extended|remux)\b",
        " ",
        cleaned,
    )
    cleaned = re.sub(r"[\._\-\[\]\(\)]+", " ", cleaned)
    return re.sub(r"\s+", " ", cleaned).strip()


def release_tokens(text: str) -> set[str]:
    tokens = re.split(r"[^A-Za-z0-9]+", text.lower())
    return {
        token
        for token in tokens
        if len(token) >= 3 and token not in {"srt", "mkv", "mp4", "avi", "mov", "webm"}
    }


def opensubtitles_search(
    config: dict[str, str],
    token: str,
    metadata: dict[str, Any],
) -> list[dict[str, Any]] | None:
    params: dict[str, Any] = {
        "languages": metadata["language"],
        "query": metadata["title"] or metadata["query"],
        "order_by": "download_count",
        "order_direction": "desc",
    }
    if metadata["season"] is not None and metadata["episode"] is not None:
        params["season_number"] = metadata["season"]
        params["episode_number"] = metadata["episode"]
    elif metadata["year"] is not None:
        params["year"] = metadata["year"]

    try:
        response = requests.get(
            f"{OPENSUBTITLES_API_URL}/subtitles",
            headers=opensubtitles_headers(config, token),
            params=params,
            timeout=SUBTITLE_SEARCH_TIMEOUT_S,
        )
        if response.status_code != 200:
            return None
        data = response.json().get("data", [])
        return data if isinstance(data, list) else []
    except (RequestException, ValueError):
        return None


def score_subtitle_candidate(candidate: dict[str, Any], metadata: dict[str, Any]) -> float:
    attrs = candidate.get("attributes") if isinstance(candidate, dict) else None
    if not isinstance(attrs, dict):
        return 0.0

    feature = attrs.get("feature_details") if isinstance(attrs.get("feature_details"), dict) else {}
    candidate_season = coerce_int(feature.get("season_number") or attrs.get("season_number"))
    candidate_episode = coerce_int(feature.get("episode_number") or attrs.get("episode_number"))
    if metadata["season"] is not None and metadata["episode"] is not None:
        if candidate_season != metadata["season"] or candidate_episode != metadata["episode"]:
            return 0.0

    score = 0.0
    language = str(attrs.get("language") or "").lower()
    if language in {"en", "eng", "english"}:
        score += 20.0

    candidate_title = str(feature.get("title") or attrs.get("title") or attrs.get("release") or "")
    title_similarity = similarity(clean_media_title(candidate_title), metadata["title"])
    score += title_similarity * 30.0

    candidate_year = coerce_int(feature.get("year") or attrs.get("year"))
    if metadata["year"] is not None:
        if candidate_year == metadata["year"]:
            score += 20.0
        elif candidate_year is not None:
            score -= 10.0
    else:
        score += 5.0

    if metadata["season"] is not None and metadata["episode"] is not None:
        score += 25.0

    files = attrs.get("files") if isinstance(attrs.get("files"), list) else []
    file_names = " ".join(
        str(file.get("file_name") or "")
        for file in files
        if isinstance(file, dict)
    )
    release = f"{attrs.get('release') or ''} {file_names}"
    release_hint_similarity = token_overlap(metadata["release_hints"], release_tokens(release))
    score += release_hint_similarity * 15.0

    if any(str(file.get("file_name") or "").lower().endswith(".srt") for file in files if isinstance(file, dict)):
        score += 10.0
    elif files:
        score -= 5.0

    return max(0.0, min(score, 100.0))


def similarity(left: str, right: str) -> float:
    if not left or not right:
        return 0.0
    return SequenceMatcher(None, left.lower(), right.lower()).ratio()


def token_overlap(left: set[str], right: set[str]) -> float:
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


def coerce_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def opensubtitles_download(
    config: dict[str, str],
    token: str,
    candidate: dict[str, Any],
) -> bytes | None:
    attrs = candidate.get("attributes") if isinstance(candidate, dict) else None
    files = attrs.get("files") if isinstance(attrs, dict) and isinstance(attrs.get("files"), list) else []
    file_id = None
    for file in files:
        if not isinstance(file, dict):
            continue
        if str(file.get("file_name") or "").lower().endswith(".srt"):
            file_id = file.get("file_id")
            break
        if file_id is None:
            file_id = file.get("file_id")
    if file_id is None:
        return None

    try:
        response = requests.post(
            f"{OPENSUBTITLES_API_URL}/download",
            headers=opensubtitles_headers(config, token),
            json={"file_id": file_id, "sub_format": "srt"},
            timeout=SUBTITLE_SEARCH_TIMEOUT_S,
        )
        if response.status_code != 200:
            return None
        link = response.json().get("link")
        if not isinstance(link, str) or not link.startswith("https://"):
            return None
        subtitle = requests.get(link, timeout=SUBTITLE_SEARCH_TIMEOUT_S)
        if subtitle.status_code != 200 or not subtitle.content:
            return None
        return subtitle.content
    except (RequestException, ValueError):
        return None


def classify_srt_quality(srt_path: Path, video_path: Path) -> str:
    try:
        content = srt_path.read_text(encoding="utf-8")
        byte_size = srt_path.stat().st_size
    except (OSError, UnicodeDecodeError):
        return "invalid_or_empty"
    return classify_srt_quality_content(content, byte_size, probe_video_duration(video_path))


def classify_srt_quality_bytes(content: bytes, video_duration: float | None) -> str:
    try:
        text = content.decode("utf-8-sig")
    except UnicodeDecodeError:
        try:
            text = content.decode("latin-1")
        except UnicodeDecodeError:
            return "invalid_or_empty"
    return classify_srt_quality_content(text, len(content), video_duration)


def classify_srt_quality_content(
    content: str,
    byte_size: int,
    video_duration: float | None,
) -> str:
    if not content.strip() or "-->" not in content:
        return "invalid_or_empty"

    cue_starts = [
        srt_timestamp_seconds(match)
        for line in content.splitlines()
        if (match := SRT_TIMING_RE.match(line)) is not None
    ]
    cue_starts = [seconds for seconds in cue_starts if seconds is not None]
    if not cue_starts:
        return "invalid_or_empty"

    first_cue_seconds = min(cue_starts)
    video_is_short = video_duration is not None and video_duration <= SRT_SHORT_VIDEO_SECONDS
    if (
        byte_size < SRT_PARTIAL_MIN_BYTES
        or len(cue_starts) < SRT_PARTIAL_MIN_CUES
        or (first_cue_seconds > SRT_LATE_FIRST_CUE_SECONDS and not video_is_short)
    ):
        return "partial_or_forced"

    return "full/usable"


def srt_timestamp_seconds(match: re.Match[str]) -> float | None:
    try:
        hours = int(match.group(1))
        minutes = int(match.group(2))
        seconds = int(match.group(3))
        millis = int((match.group(4) or "0").ljust(3, "0"))
    except (TypeError, ValueError):
        return None
    return hours * 3600 + minutes * 60 + seconds + millis / 1000


def save_downloaded_subtitle(
    content: bytes,
    srt_path: Path,
    *,
    replace_existing_partial: bool = False,
) -> bool:
    if b"-->" not in content[:1_000_000]:
        return False

    completed_root = settings.download_complete_dir.resolve()
    resolved = srt_path.resolve()
    if resolved.suffix.lower() != ".srt" or not resolved.is_relative_to(completed_root):
        return False

    tmp_path = resolved.with_name(f".{resolved.name}.tmp")
    try:
        existing = resolved.exists()
        if existing and not replace_existing_partial:
            return False
        tmp_path.write_bytes(content)
        if existing:
            backup_path = subtitle_backup_path(resolved)
            if not backup_path.exists():
                shutil.copy2(resolved, backup_path)
            os.replace(tmp_path, resolved)
        else:
            os.link(tmp_path, resolved)
        tmp_path.unlink(missing_ok=True)
        return True
    except FileExistsError:
        tmp_path.unlink(missing_ok=True)
        return False
    except OSError:
        tmp_path.unlink(missing_ok=True)
        return False


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
    with _video_progress_lock:
        return read_video_progress_unlocked()


def read_video_progress_unlocked() -> dict[str, dict[str, Any]]:
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
    with _video_progress_lock:
        write_video_progress_unlocked(progress)


def write_video_progress_unlocked(progress: dict[str, dict[str, Any]]) -> None:
    VIDEO_PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = VIDEO_PROGRESS_FILE.with_suffix(".tmp")
    tmp_path.write_text(
        json.dumps(progress, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    tmp_path.replace(VIDEO_PROGRESS_FILE)


def remove_video_progress(paths: set[str]) -> None:
    if not paths:
        return
    with _video_progress_lock:
        progress = read_video_progress_unlocked()
        changed = False
        for path in paths:
            if progress.pop(path, None) is not None:
                changed = True
        if changed:
            write_video_progress_unlocked(progress)


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


def run_auto_pause_monitor_pass() -> None:
    torrents = qb.list_torrents()
    for torrent in torrents:
        pause_if_completed_uploading(torrent)


async def auto_pause_monitor() -> None:
    while True:
        try:
            await asyncio.to_thread(run_auto_pause_monitor_pass)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            print(f"Warning: auto-pause monitor iteration failed: {exc}")
        await asyncio.sleep(15)
