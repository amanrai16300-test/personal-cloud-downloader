# Usage

Use only with legal torrents.

## Daily Flow

1. Connect device to Tailscale.
2. Open the frontend.
3. Enter API base URL.
4. Enter API key.
5. Paste a legal magnet link.
6. Add magnet paused.
7. Wait for metadata.
8. Open file list.
9. Select one file.
10. Start torrent.
11. Wait for completion.
12. Open completed file link in browser, VLC, or another player.

## Torrent Actions

- Add magnet: sends magnet to qBittorrent paused.
- Select one file: skips all files, then enables selected file.
- Start: resumes torrent.
- Pause: pauses torrent.
- Delete: removes torrent from qBittorrent. The frontend default does not request file deletion.

## Completed Files

Completed file links are built from:

```text
PUBLIC_FILE_BASE_URL + relative file path
```

Set `PUBLIC_FILE_BASE_URL` to your private Tailscale Nginx file URL.
