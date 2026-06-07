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
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_BASE_URL = "https://api.themoviedb.org/3"
IMAGE_BASE_URL = "https://image.tmdb.org/t/p/w500"
OUTPUT_PATH = Path("/tmp/trends.json")
TIMEOUT_SECONDS = 20
ITEM_LIMIT = 18
LANGUAGES = ("hi", "en")


def tmdb_get(path, params=None):
    api_key = os.environ.get("TMDB_API_KEY")
    if not api_key:
        raise RuntimeError("TMDB_API_KEY is not set.")

    query = {"api_key": api_key, **(params or {})}
    url = f"{API_BASE_URL}{path}?{urlencode(query)}"
    request = Request(url, headers={"accept": "application/json", "user-agent": "CloudBox Trends"})

    with urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_collection(path, *, media_type, params=None):
    payload = tmdb_get(path, params)
    results = payload.get("results", [])
    if not isinstance(results, list):
        return []

    items = []
    for raw_item in results[:ITEM_LIMIT]:
        if not isinstance(raw_item, dict):
            continue
        item = normalize_item(raw_item, media_type)
        item["trailer_url"] = fetch_trailer_url(media_type, raw_item.get("id"))
        items.append(item)
    return items


def fetch_india_collection(path, *, media_type):
    items = []
    seen = set()
    for language in LANGUAGES:
        payload = tmdb_get(
            path,
            {
                "sort_by": "popularity.desc",
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
            item = normalize_item(raw_item, media_type)
            item["trailer_url"] = fetch_trailer_url(media_type, tmdb_id)
            items.append(item)
            if len(items) >= ITEM_LIMIT:
                return items
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

    try:
        payload = tmdb_get(f"/{media_type}/{tmdb_id}/videos", {"language": "en-US"})
    except Exception:
        return None

    videos = payload.get("results", [])
    if not isinstance(videos, list):
        return None

    trailer = next(
        (
            video for video in videos
            if isinstance(video, dict)
            and video.get("site") == "YouTube"
            and video.get("type") == "Trailer"
            and video.get("key")
        ),
        None,
    )
    if trailer is None:
        trailer = next(
            (
                video for video in videos
                if isinstance(video, dict)
                and video.get("site") == "YouTube"
                and video.get("key")
            ),
            None,
        )
    if trailer is None:
        return None

    return f"https://www.youtube.com/watch?v={trailer['key']}"


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
        "global_movies": fetch_collection("/trending/movie/week", media_type="movie"),
        "global_series": fetch_collection("/trending/tv/week", media_type="tv"),
        "india_movies": fetch_india_collection("/discover/movie", media_type="movie"),
        "india_series": fetch_india_collection("/discover/tv", media_type="tv"),
    }
    write_json(payload)
    print(f"Wrote {OUTPUT_PATH}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Failed to fetch trends: {exc}", file=sys.stderr)
        sys.exit(1)
