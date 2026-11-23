import hashlib
import re
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


def _add_column(conn, table: str, ddl: str) -> bool:
    """列がなければ追加する。追加したら True(別のワーカーが先に追加していたら False)。"""
    name = ddl.split()[0]
    cols = {r["name"] for r in conn.execute(f"PRAGMA table_info({table})")}
    if name in cols:
        return False
    try:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {ddl}")
        return True
    except sqlite3.OperationalError:
        return False


def init(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    _add_column(conn, "folders", "cover_image_id INTEGER REFERENCES images(id) ON DELETE SET NULL")
    _add_column(conn, "items", "crop_zoom REAL NOT NULL DEFAULT 1.0")
    if _add_column(conn, "folders", "sort_mode TEXT NOT NULL DEFAULT 'name'"):
        # 初回だけ、全フォルダをファイル名順に並べ直す
        for r in conn.execute("SELECT id FROM folders").fetchall():
            renumber_by_name(conn, r["id"])
    conn.commit()


def natural_key(s: str | None):
    if s is None:
        return [[1]]
    return [[0], *[(0, int(t)) if t.isdigit() else (1, t.lower()) for t in re.split(r"(\d+)", s) if t != ""]]


def renumber_by_name(conn, folder_id: int) -> None:
    rows = conn.execute("SELECT id, original_name FROM items WHERE folder_id = ?", (folder_id,)).fetchall()
    rows.sort(key=lambda r: (natural_key(r["original_name"]), r["id"]))
    conn.executemany("UPDATE items SET position = ? WHERE id = ?", [(i, r["id"]) for i, r in enumerate(rows)])


def set_sort_mode(conn, folder_id: int, mode: str) -> None:
    conn.execute("UPDATE folders SET sort_mode = ? WHERE id = ?", (mode, folder_id))
    if mode == "name":
        renumber_by_name(conn, folder_id)


def move_item(conn, item_id: int, to_index: int) -> int:
    """フォルダ内で並び順を移動し、フォルダを手動並びに切り替える。フォルダ ID を返す。"""
    row = conn.execute("SELECT folder_id FROM items WHERE id = ?", (item_id,)).fetchone()
    if row is None:
        raise FolderError("画像がありません")
    fid = row["folder_id"]
    ids = [r["id"] for r in conn.execute("SELECT id FROM items WHERE folder_id = ? ORDER BY position, id", (fid,))]
    ids.remove(item_id)
    to_index = max(0, min(to_index, len(ids)))
    ids.insert(to_index, item_id)
    conn.executemany("UPDATE items SET position = ? WHERE id = ?", [(i, x) for i, x in enumerate(ids)])
    conn.execute("UPDATE folders SET sort_mode = 'manual' WHERE id = ?", (fid,))
    return fid


def delete_items(conn, item_ids: list[int]) -> list[int]:
    """フォルダから外す。どのフォルダからも参照されなくなった画像の ID を返す。"""
    if not item_ids:
        return []
    marks = ",".join("?" * len(item_ids))
    image_ids = [r[0] for r in conn.execute(f"SELECT DISTINCT image_id FROM items WHERE id IN ({marks})", item_ids)]
    conn.execute(f"DELETE FROM items WHERE id IN ({marks})", item_ids)
    return unreferenced(conn, image_ids)


def delete_folder(conn, folder_id: int) -> list[int]:
    """フォルダと子フォルダを消す。どこからも参照されなくなった画像の ID を返す。"""
    image_ids = [r[0] for r in conn.execute(
        """SELECT DISTINCT image_id FROM items WHERE folder_id = ?
           OR folder_id IN (SELECT id FROM folders WHERE parent_id = ?)""",
        (folder_id, folder_id),
    )]
    conn.execute("DELETE FROM items WHERE folder_id IN (SELECT id FROM folders WHERE parent_id = ?)", (folder_id,))
    conn.execute("DELETE FROM items WHERE folder_id = ?", (folder_id,))
    conn.execute("DELETE FROM folders WHERE parent_id = ?", (folder_id,))
    conn.execute("DELETE FROM folders WHERE id = ?", (folder_id,))
    return unreferenced(conn, image_ids)


def unreferenced(conn, image_ids: list[int]) -> list[int]:
    return [i for i in image_ids
            if conn.execute("SELECT 1 FROM items WHERE image_id = ? LIMIT 1", (i,)).fetchone() is None]


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


def rename_folder(conn, folder_id: int, name: str) -> None:
    name = name.strip()
    if not name:
        raise FolderError("フォルダ名が空です")
    row = conn.execute("SELECT * FROM folders WHERE id = ?", (folder_id,)).fetchone()
    if row is None:
        raise FolderError("フォルダがありません")
    other = find_folder(conn, name, row["parent_id"])
    if other is not None and other["id"] != folder_id:
        raise FolderError("同じ名前のフォルダがあります")
    conn.execute("UPDATE folders SET name = ? WHERE id = ?", (name, folder_id))


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


def add_item(conn, folder_id: int, image_id: int, original_name: str | None, renumber: bool = True) -> int | None:
    """フォルダに追加する。ファイル名順のフォルダでは名前の位置に、手動並びのフォルダでは末尾に入る。
    同じ画像がすでにあれば None。renumber=False なら並べ直しは呼び出し側でまとめて行う。"""
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
    if renumber:
        mode = conn.execute("SELECT sort_mode FROM folders WHERE id = ?", (folder_id,)).fetchone()
        if mode is not None and mode[0] == "name":
            renumber_by_name(conn, folder_id)
    return cur.lastrowid


# ---- tokens ----

def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def check_token(conn, token: str) -> bool:
    h = hash_token(token)
    row = conn.execute("SELECT id, last_used_at FROM tokens WHERE token_hash = ?", (h,)).fetchone()
    if row is None:
        return False
    # 画像1枚ごとに HDD へ書き込まないよう、最終使用日時の更新は1分に1回まで
    last = row["last_used_at"]
    if last is None or (datetime.now(timezone.utc) - datetime.fromisoformat(last)).total_seconds() >= 60:
        conn.execute("UPDATE tokens SET last_used_at = ? WHERE id = ?", (now(), row["id"]))
        conn.commit()
    return True
