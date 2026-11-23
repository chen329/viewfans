import os
from pathlib import Path

DATA_DIR = Path(os.environ.get("VIEWFANS_DATA", "/srv/viewfans"))
ORIGINALS_DIR = DATA_DIR / "originals"
THUMBS_DIR = DATA_DIR / "thumbs"
MEDIUM_DIR = DATA_DIR / "medium"
DB_PATH = DATA_DIR / "db" / "viewfans.sqlite"

THUMB_LONG_EDGE = 600
THUMB_QUALITY = 85
MEDIUM_LONG_EDGE = 1600
MEDIUM_QUALITY = 88

# 拡張子 → 保存時の拡張子
SUPPORTED_EXT = {
    "jpg": "jpg",
    "jpeg": "jpg",
    "png": "png",
    "webp": "webp",
    "heic": "heic",
    "heif": "heic",
}

MEDIA_TYPES = {
    "jpg": "image/jpeg",
    "png": "image/png",
    "webp": "image/webp",
    "heic": "image/heic",
}
