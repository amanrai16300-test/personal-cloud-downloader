import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(dotenv_path=Path(__file__).with_name(".env"))


class Settings:
    app_host: str = os.getenv("APP_HOST", "0.0.0.0")
    app_port: int = int(os.getenv("APP_PORT", "8000"))
    qb_url: str = os.getenv("QB_URL", "http://127.0.0.1:8080").rstrip("/")
    qb_username: str = os.getenv("QB_USERNAME", "admin")
    qb_password: str = os.getenv("QB_PASSWORD", "")
    download_complete_dir: Path = Path(
        os.getenv("DOWNLOAD_COMPLETE_DIR", "/srv/personal-cloud/downloads/complete")
    )
    download_incomplete_dir: Path = Path(
        os.getenv("DOWNLOAD_INCOMPLETE_DIR", "/srv/personal-cloud/downloads/incomplete")
    )
    stream_base_url: str = os.getenv("STREAM_BASE_URL", "").rstrip("/")
    max_download_gb: float = float(os.getenv("MAX_DOWNLOAD_GB", "10"))
    auto_pause_on_complete: bool = os.getenv("AUTO_PAUSE_ON_COMPLETE", "true").lower() == "true"
    delete_files_only_on_user_action: bool = (
        os.getenv("DELETE_FILES_ONLY_ON_USER_ACTION", "true").lower() == "true"
    )


settings = Settings()
