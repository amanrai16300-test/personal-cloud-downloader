#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_DIR="${DOWNLOAD_DIR:-/srv/torrents/downloads}"
INCOMPLETE_DIR="${INCOMPLETE_DIR:-/srv/torrents/incomplete}"
DAYS_TO_KEEP_COMPLETED="${DAYS_TO_KEEP_COMPLETED:-3}"
DAYS_TO_KEEP_INCOMPLETE="${DAYS_TO_KEEP_INCOMPLETE:-2}"
DRY_RUN="${DRY_RUN:-1}"

run_find() {
  local target_dir="$1"
  local days="$2"

  if [ ! -d "$target_dir" ]; then
    echo "Skip missing directory: $target_dir"
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    find "$target_dir" -type f -mtime +"$days" -print
  else
    find "$target_dir" -type f -mtime +"$days" -print -delete
    find "$target_dir" -type d -empty -print -delete
  fi
}

echo "Cleanup mode: DRY_RUN=$DRY_RUN"
echo "Completed older than $DAYS_TO_KEEP_COMPLETED days:"
run_find "$DOWNLOAD_DIR" "$DAYS_TO_KEEP_COMPLETED"
echo "Incomplete older than $DAYS_TO_KEEP_INCOMPLETE days:"
run_find "$INCOMPLETE_DIR" "$DAYS_TO_KEEP_INCOMPLETE"
echo "Done."
