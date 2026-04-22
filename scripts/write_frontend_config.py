import json
import os
from pathlib import Path


api_base_url = os.environ.get("API_BASE_URL", "http://localhost:8000").rstrip("/")
config = {"API_BASE_URL": api_base_url}

Path("/app/config.js").write_text(
    f"window.NGX_DASH_CONFIG = {json.dumps(config)};\n",
    encoding="utf-8",
)
