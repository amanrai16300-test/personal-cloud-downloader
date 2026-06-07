#!/usr/bin/env python3
"""Fetch CloudBox Trends from TMDB metadata only.

Usage:
  export TMDB_API_KEY="your_tmdb_api_key"
  python3 scripts/fetch_trends.py

Cron example:
  0 */6 * * * cd /home/ubuntu/personal-cloud-downloader && /usr/bin/python3 scripts/fetch_trends.py
"""

import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_BASE_URL = "https://api.themoviedb.org/3"
IMAGE_BASE_URL = "https://image.tmdb.org/t/p/w500"
OUTPUT_PATH = Path("/tmp/trends.json")
TIMEOUT_SECONDS = 20
ITEM_LIMIT = 15
LANGUAGES = ("hi", "en")
RECENT_MOVIE_DAYS = 120
RECENT_TV_DAYS = 90
MOVIE_FALLBACK_DAYS = (120, 180, 365)
TV_FALLBACK_DAYS = (90, 180, 365)
MIN_VOTES = 5
MIN_FALLBACK_ITEMS = 8
MAX_PAGES = 5
TRAILER_LANGUAGES = ("en-US", "hi-IN")
BAD_TRAILER_WORDS = (
    "clip",
    "featurette",
    "interview",
    "promo",
    "reaction",
    "recap",
    "review",
    "song",
    "teaser",
)


def tmdb_get(path, params=None):
    api_key = os.environ.get("TMDB_API_KEY")
    if not api_key:
        raise RuntimeError("TMDB_API_KEY is not set.")

    query = {"api_key": api_key, **(params or {})}
    url = f"{API_BASE_URL}{path}?{urlencode(query)}"
    request = Request(url, headers={"accept": "application/json", "user-agent": "CloudBox Trends"})

    with urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def recent_date_range(days):
    today = datetime.now(timezone.utc).date()
    start = today - timedelta(days=days)
    return start.isoformat(), today.isoformat()


def item_date(raw_item):
    value = raw_item.get("release_date") or raw_item.get("first_air_date") or ""
    return value if isinstance(value, str) else ""


def is_recent(raw_item, start_date, end_date):
    value = item_date(raw_item)
    return bool(value) and start_date <= value <= end_date


def rank_items(raw_items, start_date, end_date):
    filtered = [
        item for item in raw_items
        if isinstance(item, dict)
        and is_recent(item, start_date, end_date)
        and (item.get("vote_count") or 0) >= MIN_VOTES
    ]
    return sorted(
        filtered,
        key=lambda item: (
            item_date(item),
            item.get("popularity") or 0,
            item.get("vote_average") or 0,
        ),
        reverse=True,
    )


def fetch_pages(path, params=None):
    raw_items = []
    for page in range(1, MAX_PAGES + 1):
        payload = tmdb_get(path, {**(params or {}), "page": page})
        results = payload.get("results", [])
        if isinstance(results, list):
            raw_items.extend(results)
    return raw_items


def fetch_collection(path, *, media_type, params=None, fallback_days):
    best_items = []
    for days in fallback_days:
        start_date, end_date = recent_date_range(days)
        ranked_items = rank_items(fetch_pages(path, params), start_date, end_date)
        if len(ranked_items) > len(best_items):
            best_items = ranked_items
        if len(ranked_items) >= MIN_FALLBACK_ITEMS:
            return normalize_collection(ranked_items, media_type)

    return normalize_collection(best_items, media_type)


def fetch_discover_collection(path, *, media_type, base_params=None, fallback_days):
    best_items = []
    for days in fallback_days:
        start_date, end_date = recent_date_range(days)
        params = {
            **recent_discover_params(media_type, start_date, end_date),
            **(base_params or {}),
        }
        ranked_items = rank_items(fetch_pages(path, params), start_date, end_date)
        if len(ranked_items) > len(best_items):
            best_items = ranked_items
        if len(ranked_items) >= MIN_FALLBACK_ITEMS:
            return normalize_collection(ranked_items, media_type)

    return normalize_collection(best_items, media_type)


def fetch_india_collection(path, *, media_type, fallback_days):
    best_items = []
    for days in fallback_days:
        start_date, end_date = recent_date_range(days)
        ranked_items = rank_items(fetch_india_window(path, media_type, start_date, end_date), start_date, end_date)
        if len(ranked_items) > len(best_items):
            best_items = ranked_items
        if len(ranked_items) >= MIN_FALLBACK_ITEMS:
            return normalize_collection(ranked_items, media_type)

    return normalize_collection(best_items, media_type)


def fetch_india_window(path, media_type, start_date, end_date):
    raw_items = []
    seen = set()
    for language in LANGUAGES:
        for page in range(1, MAX_PAGES + 1):
            payload = tmdb_get(
                path,
                {
                    **recent_discover_params(media_type, start_date, end_date),
                    "page": page,
                    "region": "IN",
                    "with_origin_country": "IN",
                    "with_original_language": language,
                    "include_adult": "false",
                },
            )
            results = payload.get("results", [])
            if not isinstance(results, list):
                continue
            for raw_item in results:
                if not isinstance(raw_item, dict):
                    continue
                tmdb_id = raw_item.get("id")
                if tmdb_id in seen:
                    continue
                seen.add(tmdb_id)
                raw_items.append(raw_item)
    return raw_items


def recent_discover_params(media_type, start_date, end_date):
    if media_type == "movie":
        return {
            "sort_by": "primary_release_date.desc",
            "primary_release_date.gte": start_date,
            "primary_release_date.lte": end_date,
            "vote_count.gte": MIN_VOTES,
        }
    return {
        "sort_by": "first_air_date.desc",
        "first_air_date.gte": start_date,
        "first_air_date.lte": end_date,
        "vote_count.gte": MIN_VOTES,
    }


def normalize_collection(raw_items, media_type):
    items = []
    for raw_item in raw_items[:ITEM_LIMIT]:
        item = normalize_item(raw_item, media_type)
        item["trailer_url"] = fetch_trailer_url(media_type, raw_item.get("id"))
        items.append(item)
    return items


def normalize_item(raw_item, media_type):
    title = raw_item.get("title") or raw_item.get("name") or "Untitled"
    date_value = raw_item.get("release_date") or raw_item.get("first_air_date") or ""
    release_year = date_value[:4] if isinstance(date_value, str) and len(date_value) >= 4 else None
    poster_path = raw_item.get("poster_path")

    return {
        "title": title,
        "poster_url": f"{IMAGE_BASE_URL}{poster_path}" if poster_path else None,
        "rating": raw_item.get("vote_average"),
        "release_year": release_year,
        "trailer_url": None,
        "media_type": media_type,
        "language": raw_item.get("original_language"),
    }


def fetch_trailer_url(media_type, tmdb_id):
    if not tmdb_id:
        return None

    videos = []
    for language in TRAILER_LANGUAGES:
        try:
            payload = tmdb_get(f"/{media_type}/{tmdb_id}/videos", {"language": language})
        except Exception:
            continue

        results = payload.get("results", [])
        if isinstance(results, list):
            videos.extend(results)

    trailer = best_trailer(videos)
    if not trailer:
        return None

    return f"https://www.youtube.com/watch?v={trailer['key']}"


def best_trailer(videos):
    candidates = [
        video for video in videos
        if isinstance(video, dict)
        and video.get("site") == "YouTube"
        and video.get("type") == "Trailer"
        and video.get("official") is True
        and video.get("key")
        and not has_bad_trailer_title(video)
    ]
    if not candidates:
        return None

    return sorted(
        candidates,
        key=lambda video: (
            trailer_language_score(video),
            "official trailer" in (video.get("name") or "").lower(),
            video.get("published_at") or "",
        ),
        reverse=True,
    )[0]


def has_bad_trailer_title(video):
    name = (video.get("name") or "").lower()
    return any(word in name for word in BAD_TRAILER_WORDS)


def trailer_language_score(video):
    language = video.get("iso_639_1")
    if language == "en":
        return 2
    if language == "hi":
        return 1
    return 0


def write_json(payload):
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=OUTPUT_PATH.parent, delete=False) as temp_file:
        json.dump(payload, temp_file, indent=2, ensure_ascii=False)
        temp_file.write("\n")
        temp_path = Path(temp_file.name)
    temp_path.replace(OUTPUT_PATH)


def main():
    payload = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "global_movies": fetch_collection(
            "/movie/now_playing",
            media_type="movie",
            params={"region": "US", "include_adult": "false"},
            fallback_days=MOVIE_FALLBACK_DAYS,
        ),
        "global_series": fetch_discover_collection(
            "/discover/tv",
            media_type="tv",
            base_params={
                "with_status": "0",
                "include_adult": "false",
            },
            fallback_days=TV_FALLBACK_DAYS,
        ),
        "india_movies": fetch_india_collection(
            "/discover/movie",
            media_type="movie",
            fallback_days=MOVIE_FALLBACK_DAYS,
        ),
        "india_series": fetch_india_collection(
            "/discover/tv",
            media_type="tv",
            fallback_days=TV_FALLBACK_DAYS,
        ),
    }
    write_json(payload)
    print(f"Wrote {OUTPUT_PATH}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Failed to fetch trends: {exc}", file=sys.stderr)
        sys.exit(1)
