#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

command -v oci >/dev/null 2>&1 || die "OCI CLI is not available in PATH."
command -v tar >/dev/null 2>&1 || die "tar is not available in PATH."

bucket="${CLOUDBOX_BACKUP_BUCKET:-}"
[[ -n "$bucket" ]] || die "CLOUDBOX_BACKUP_BUCKET is required."

prefix="${CLOUDBOX_BACKUP_PREFIX:-}"
profile="${OCI_CLI_PROFILE:-}"
keep_local="${CLOUDBOX_BACKUP_KEEP_LOCAL:-false}"

timestamp="$(date +%Y%m%d-%H%M)"
backup_name="cloudbox-app-backup-${timestamp}.tar.gz"
work_dir="$(mktemp -d /tmp/cloudbox-app-backup.XXXXXX)"
manifest_dir="${work_dir}/cloudbox-backup-manifest"
tarball="/tmp/${backup_name}"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$manifest_dir"

if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${binary:Package}\t${Version}\n' > "${manifest_dir}/cloudbox-installed-packages.txt"
else
  printf 'dpkg-query unavailable\n' > "${manifest_dir}/cloudbox-installed-packages.txt"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl list-unit-files --type=service --no-pager > "${manifest_dir}/cloudbox-systemd-units.txt"
else
  printf 'systemctl unavailable\n' > "${manifest_dir}/cloudbox-systemd-units.txt"
fi

paths=(
  "/home/ubuntu/personal-cloud-downloader"
  "/home/ubuntu/.config/cloudbox"
  "/etc/systemd/system/personal-downloader-api.service"
  "/etc/nginx/sites-available"
  "/etc/nginx/sites-enabled"
  "/etc/cron.d/cloudbox-trends"
  "/var/www/personal-cloud"
  "/home/ubuntu/.config/qBittorrent"
  "/home/ubuntu/.local/share/qBittorrent"
  "$manifest_dir"
)

shopt -s nullglob
for unit in /etc/systemd/system/qbittorrent*.service; do
  paths+=("$unit")
done
shopt -u nullglob

if [[ -e /var/lib/cloudbox ]]; then
  paths+=("/var/lib/cloudbox")
fi

existing_paths=()
for path in "${paths[@]}"; do
  if [[ -e "$path" ]]; then
    existing_paths+=("$path")
  else
    log "Skipping missing path: $path"
  fi
done

[[ "${#existing_paths[@]}" -gt 0 ]] || die "No backup paths exist."

log "Creating backup: ${tarball}"
tar \
  --create \
  --gzip \
  --file "$tarball" \
  --absolute-names \
  --warning=no-file-changed \
  --exclude="/srv/personal-cloud/downloads" \
  --exclude="/srv/personal-cloud/downloads/*" \
  --exclude="*.mp4" \
  --exclude="*.mkv" \
  --exclude="*.avi" \
  --exclude="*.mov" \
  --exclude="*.webm" \
  --exclude="*.!qB" \
  --exclude="*.part" \
  --exclude="*.partial" \
  --exclude="*.crdownload" \
  --exclude="*.aria2" \
  --exclude="*/incomplete/*" \
  --exclude="*/.incomplete/*" \
  --exclude="*/thumbnails/*" \
  --exclude="*/thumbs/*" \
  --exclude="*/subtitles/*" \
  --exclude="*/subs/*" \
  --exclude="*.srt" \
  --exclude="*.vtt" \
  --exclude="*.ass" \
  --exclude="*.ssa" \
  "${existing_paths[@]}"

object_name="${backup_name}"
if [[ -n "$prefix" ]]; then
  prefix="${prefix#/}"
  prefix="${prefix%/}"
  object_name="${prefix}/${backup_name}"
fi

oci_args=(os object put --bucket-name "$bucket" --name "$object_name" --file "$tarball")
if [[ -n "$profile" ]]; then
  oci_args+=(--profile "$profile")
fi

log "Uploading backup to OCI Object Storage: ${object_name}"
oci "${oci_args[@]}"

if [[ "$keep_local" == "true" ]]; then
  log "Keeping local backup: ${tarball}"
else
  rm -f "$tarball"
  log "Deleted local backup: ${tarball}"
fi

log "CloudBox app backup complete."
