#!/usr/bin/env python3
"""Fetch CloudBox Trends from TMDB metadata only.

Usage:
  export TMDB_API_KEY="your_tmdb_api_key"
  python3 scripts/fetch_trends.py

Cron example:
  0 */6 * * * cd /home/ubuntu/personal-cloud-downloader && /usr/bin/python3 scripts/fetch_trends.py
"""

import json
import math
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
TRENDING_SOURCE_BONUS = 80
MAX_GLOBAL_AGE_DAYS = 730
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


def recent_activity_date(raw_item):
    values = (
        raw_item.get("last_air_date"),
        raw_item.get("next_episode_to_air", {}).get("air_date")
        if isinstance(raw_item.get("next_episode_to_air"), dict)
        else None,
        raw_item.get("last_episode_to_air", {}).get("air_date")
        if isinstance(raw_item.get("last_episode_to_air"), dict)
        else None,
    )
    for value in values:
        if isinstance(value, str) and value:
            return value
    return ""


def is_recent(raw_item, start_date, end_date):
    value = item_date(raw_item)
    return bool(value) and start_date <= value <= end_date


def parse_item_date(raw_item):
    value = item_date(raw_item)
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).date()
    except ValueError:
        return None


def item_age_days(raw_item, date_getter=item_date):
    date_value = parse_item_date_value(date_getter(raw_item))
    if not date_value:
        return None
    return (datetime.now(timezone.utc).date() - date_value).days


def parse_item_date_value(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).date()
    except ValueError:
        return None


def is_trending_week(raw_item):
    return "trending_week" in raw_item.get("_trend_sources", ())


def is_allowed_by_age(raw_item, media_type=None, freshness_scope="all"):
    if freshness_scope != "global":
        return True

    age_days = item_age_days(raw_item)
    if age_days is None:
        return True
    if age_days <= MAX_GLOBAL_AGE_DAYS:
        return True
    if media_type != "tv":
        return False

    activity_age_days = item_age_days(raw_item, recent_activity_date)
    return activity_age_days is not None and activity_age_days <= MAX_GLOBAL_AGE_DAYS


def score_item(raw_item):
    age_days = item_age_days(raw_item)
    recency_score = 0 if age_days is None else max(0, 365 - age_days) / 3
    return (
        (raw_item.get("popularity") or 0)
        + math.sqrt(raw_item.get("vote_count") or 0)
        + ((raw_item.get("vote_average") or 0) * 4)
        + recency_score
        + (TRENDING_SOURCE_BONUS if is_trending_week(raw_item) else 0)
    )


def rank_items(raw_items, start_date=None, end_date=None, media_type=None, freshness_scope="all"):
    filtered = [
        item for item in raw_items
        if isinstance(item, dict)
        and (not start_date or not end_date or is_recent(item, start_date, end_date))
        and is_allowed_by_age(item, media_type, freshness_scope)
        and (item.get("vote_count") or 0) >= MIN_VOTES
    ]
    return sorted(
        filtered,
        key=lambda item: (
            score_item(item),
            item.get("popularity") or 0,
            item_date(item),
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


def tag_items(raw_items, source_name):
    tagged_items = []
    for raw_item in raw_items:
        if not isinstance(raw_item, dict):
            continue
        item = dict(raw_item)
        item["_trend_sources"] = {source_name}
        tagged_items.append(item)
    return tagged_items


def merge_deduped(raw_items):
    merged = {}
    for raw_item in raw_items:
        tmdb_id = raw_item.get("id")
        if not tmdb_id:
            continue
        if tmdb_id not in merged:
            merged[tmdb_id] = dict(raw_item)
            merged[tmdb_id]["_trend_sources"] = set(raw_item.get("_trend_sources", ()))
            continue

        current = merged[tmdb_id]
        current["_trend_sources"].update(raw_item.get("_trend_sources", ()))
        for key in ("popularity", "vote_count", "vote_average"):
            current[key] = max(current.get(key) or 0, raw_item.get(key) or 0)
        if (raw_item.get("last_air_date") or "") > (current.get("last_air_date") or ""):
            current["last_air_date"] = raw_item.get("last_air_date")
        for key in ("next_episode_to_air", "last_episode_to_air"):
            raw_episode = raw_item.get(key)
            current_episode = current.get(key)
            if (
                isinstance(raw_episode, dict)
                and (
                    not isinstance(current_episode, dict)
                    or (raw_episode.get("air_date") or "") > (current_episode.get("air_date") or "")
                )
            ):
                current[key] = raw_episode
        if item_date(raw_item) > item_date(current):
            current.update({key: value for key, value in raw_item.items() if key != "_trend_sources"})
    return list(merged.values())


def fetch_global_collection(*, media_type, sources, fallback_days):
    best_items = []
    for days in fallback_days:
        start_date, end_date = recent_date_range(days)
        raw_items = []
        for source in sources:
            params = dict(source.get("params") or {})
            if source.get("recent_discover"):
                params.update(recent_discover_params(media_type, start_date, end_date))
            raw_items.extend(tag_items(fetch_pages(source["path"], params), source["name"]))

        ranked_items = rank_items(merge_deduped(raw_items), media_type=media_type, freshness_scope="global")
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
                    "sort_by": "popularity.desc",
                    "include_adult": "false",
                },
            )
            results = payload.get("results", [])
            if not isinstance(results, list):
                continue
            for raw_item in results:
                if not isinstance(raw_item, dict):
                    continue
                raw_item["_trend_sources"] = {"india_discover"}
                raw_items.append(raw_item)
    return merge_deduped(raw_items)


def recent_discover_params(media_type, start_date, end_date):
    if media_type == "movie":
        return {
            "sort_by": "popularity.desc",
            "primary_release_date.gte": start_date,
            "primary_release_date.lte": end_date,
            "vote_count.gte": MIN_VOTES,
        }
    return {
        "sort_by": "popularity.desc",
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
        "global_movies": fetch_global_collection(
            media_type="movie",
            sources=[
                {"name": "trending_week", "path": "/trending/movie/week"},
                {"name": "now_playing", "path": "/movie/now_playing", "params": {"region": "US"}},
                {"name": "popular", "path": "/movie/popular", "params": {"region": "US"}},
                {
                    "name": "recent_discover",
                    "path": "/discover/movie",
                    "params": {"include_adult": "false"},
                    "recent_discover": True,
                },
            ],
            fallback_days=MOVIE_FALLBACK_DAYS,
        ),
        "global_series": fetch_global_collection(
            media_type="tv",
            sources=[
                {"name": "trending_week", "path": "/trending/tv/week"},
                {"name": "on_the_air", "path": "/tv/on_the_air"},
                {"name": "popular", "path": "/tv/popular"},
                {
                    "name": "recent_discover",
                    "path": "/discover/tv",
                    "params": {"with_status": "0", "include_adult": "false"},
                    "recent_discover": True,
                },
            ],
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
