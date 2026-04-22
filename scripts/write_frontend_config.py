import json
import os
from pathlib import Path


def normalize_api_base_url(value: str) -> str:
    value = value.strip().rstrip("/")
    if value.startswith(("http://", "https://")):
        return value
    if value.startswith(("localhost", "127.0.0.1", "10.0.2.2")):
        return f"http://{value}"
    return f"https://{value}"


api_base_url = normalize_api_base_url(os.environ.get("API_BASE_URL", "http://localhost:8000"))
config = {"API_BASE_URL": api_base_url}

Path("/app/config.js").write_text(
    f"window.NGX_DASH_CONFIG = {json.dumps(config)};\n",
    encoding="utf-8",
)
