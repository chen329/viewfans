import hashlib
import sqlite3
from datetime import datetime, timezone

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS folders (
    id         INTEGER PRIMARY KEY,
    parent_id  INTEGER REFERENCES folders(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    position   INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent_id, position);

CREATE TABLE IF NOT EXISTS images (
    id         INTEGER PRIMARY KEY,
    sha256     TEXT NOT NULL UNIQUE,
    ext        TEXT NOT NULL,
    width      INTEGER NOT NULL,
    height     INTEGER NOT NULL,
    bytes      INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
    id            INTEGER PRIMARY KEY,
    folder_id     INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    image_id      INTEGER NOT NULL REFERENCES images(id),
    position      INTEGER NOT NULL,
    crop_x        REAL NOT NULL DEFAULT 0.5,
    crop_y        REAL NOT NULL DEFAULT 0.5,
    original_name TEXT,
    created_at    TEXT NOT NULL,
    UNIQUE(folder_id, image_id)
);
CREATE INDEX IF NOT EXISTS items_folder ON items(folder_id, position);

CREATE TABLE IF NOT EXISTS tokens (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    token_hash   TEXT NOT NULL UNIQUE,
    created_at   TEXT NOT NULL,
    last_used_at TEXT
);
"""


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def connect() -> sqlite3.Connection:
    config.DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(config.DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def init(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


# ---- folders ----

class FolderError(Exception):
    pass


def find_folder(conn, name: str, parent_id: int | None):
    if parent_id is None:
        return conn.execute(
            "SELECT * FROM folders WHERE parent_id IS NULL AND name = ?", (name,)
        ).fetchone()
    return conn.execute(
        "SELECT * FROM folders WHERE parent_id = ? AND name = ?", (parent_id, name)
    ).fetchone()


def create_folder(conn, name: str, parent_id: int | None) -> int:
    name = name.strip()
    if not name:
        raise FolderError("フォルダ名が空です")
    if parent_id is not None:
        parent = conn.execute("SELECT * FROM folders WHERE id = ?", (parent_id,)).fetchone()
        if parent is None:
            raise FolderError("親フォルダがありません")
        if parent["parent_id"] is not None:
            raise FolderError("フォルダは2段までです")
    if find_folder(conn, name, parent_id) is not None:
        raise FolderError("同じ名前のフォルダがあります")
    if parent_id is None:
        pos = conn.execute(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM folders WHERE parent_id IS NULL"
        ).fetchone()[0]
    else:
        pos = conn.execute(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM folders WHERE parent_id = ?",
            (parent_id,),
        ).fetchone()[0]
    cur = conn.execute(
        "INSERT INTO folders(parent_id, name, position, created_at) VALUES (?, ?, ?, ?)",
        (parent_id, name, pos, now()),
    )
    return cur.lastrowid


def get_or_create_folder(conn, name: str, parent_id: int | None) -> int:
    row = find_folder(conn, name, parent_id)
    if row is not None:
        return row["id"]
    return create_folder(conn, name, parent_id)


# ---- images / items ----

def find_image(conn, sha256: str):
    return conn.execute("SELECT * FROM images WHERE sha256 = ?", (sha256,)).fetchone()


def insert_image(conn, sha256: str, ext: str, width: int, height: int, size: int) -> int:
    cur = conn.execute(
        "INSERT INTO images(sha256, ext, width, height, bytes, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        (sha256, ext, width, height, size, now()),
    )
    return cur.lastrowid


def add_item(conn, folder_id: int, image_id: int, original_name: str | None) -> int | None:
    """フォルダの末尾に追加する。同じ画像がすでにあれば None。"""
    exists = conn.execute(
        "SELECT id FROM items WHERE folder_id = ? AND image_id = ?", (folder_id, image_id)
    ).fetchone()
    if exists is not None:
        return None
    pos = conn.execute(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM items WHERE folder_id = ?", (folder_id,)
    ).fetchone()[0]
    cur = conn.execute(
        "INSERT INTO items(folder_id, image_id, position, original_name, created_at) VALUES (?, ?, ?, ?, ?)",
        (folder_id, image_id, pos, original_name, now()),
    )
    return cur.lastrowid


# ---- tokens ----

def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def check_token(conn, token: str) -> bool:
    h = hash_token(token)
    row = conn.execute("SELECT id FROM tokens WHERE token_hash = ?", (h,)).fetchone()
    if row is None:
        return False
    conn.execute("UPDATE tokens SET last_used_at = ? WHERE id = ?", (now(), row["id"]))
    conn.commit()
    return True
