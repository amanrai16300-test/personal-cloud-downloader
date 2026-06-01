from typing import Any

import requests

from settings import settings


class QBittorrentClient:
    def __init__(self) -> None:
        self.base_url = settings.qb_url
        self.session = requests.Session()

    def login(self) -> None:
        response = self.session.post(
            f"{self.base_url}/api/v2/auth/login",
            data={"username": settings.qb_username, "password": settings.qb_password},
            timeout=10,
        )
        if response.status_code != 200 or response.text.strip().lower() == "fails.":
            raise RuntimeError("qBittorrent login failed.")

    def test_connection(self) -> None:
        self.login()
        response = self.session.get(f"{self.base_url}/api/v2/app/version", timeout=10)
        response.raise_for_status()

    def add_magnet(self, magnet: str) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/add",
            data={
                "urls": magnet,
                "savepath": str(settings.download_complete_dir),
                "root_folder": "false",
            },
            timeout=20,
        )
        response.raise_for_status()

    def list_torrents(self) -> list[dict[str, Any]]:
        self.login()
        response = self.session.get(f"{self.base_url}/api/v2/torrents/info", timeout=10)
        response.raise_for_status()
        return response.json()

    def get_files(self, torrent_hash: str) -> list[dict[str, Any]]:
        self.login()
        response = self.session.get(
            f"{self.base_url}/api/v2/torrents/files",
            params={"hash": torrent_hash},
            timeout=10,
        )
        response.raise_for_status()
        return response.json()

    def set_file_priority(self, torrent_hash: str, file_ids: list[int], priority: int) -> None:
        if not file_ids:
            return

        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/filePrio",
            data={
                "hash": torrent_hash,
                "id": "|".join(str(file_id) for file_id in file_ids),
                "priority": priority,
            },
            timeout=10,
        )
        response.raise_for_status()

    def select_only_one_file(self, torrent_hash: str, selected_file_id: int) -> None:
        files = self.get_files(torrent_hash)
        all_ids = [int(file_info["index"]) for file_info in files]

        if selected_file_id not in all_ids:
            raise ValueError("Selected file id does not exist in torrent.")

        self.set_file_priority(torrent_hash, all_ids, 0)
        self.set_file_priority(torrent_hash, [selected_file_id], 1)

    def start(self, torrent_hash: str) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/resume",
            data={"hashes": torrent_hash},
            timeout=10,
        )
        response.raise_for_status()

    def pause(self, torrent_hash: str) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/pause",
            data={"hashes": torrent_hash},
            timeout=10,
        )
        response.raise_for_status()

    def delete(self, torrent_hash: str, delete_files: bool = True) -> None:
        self.login()
        response = self.session.post(
            f"{self.base_url}/api/v2/torrents/delete",
            data={"hashes": torrent_hash, "deleteFiles": "true" if delete_files else "false"},
            timeout=10,
        )
        response.raise_for_status()
