import hashlib
import re
import sqlite3
from datetime import datetime, timedelta, timezone

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

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

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
    _add_column(conn, "folders", "cover_crop_x REAL NOT NULL DEFAULT 0.5")
    _add_column(conn, "folders", "cover_crop_y REAL NOT NULL DEFAULT 0.5")
    _add_column(conn, "folders", "cover_crop_zoom REAL NOT NULL DEFAULT 1.0")
    _add_column(conn, "folders", "deleted_at TEXT")
    _add_column(conn, "items", "deleted_at TEXT")
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


def _folder_sort_key(parent_id: int | None) -> str:
    return f"folder_sort:{'root' if parent_id is None else parent_id}"


def folder_sort_mode(conn, parent_id: int | None) -> str:
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (_folder_sort_key(parent_id),)).fetchone()
    return row["value"] if row else "name"


def set_folder_sort_mode(conn, parent_id: int | None, mode: str) -> None:
    conn.execute(
        "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (_folder_sort_key(parent_id), mode),
    )


def ordered_folders(conn, parent_id: int | None) -> list:
    """フォルダの並び。初期状態は名前順、並べ替えたあとは手動の並び。"""
    if parent_id is None:
        rows = conn.execute("SELECT * FROM folders WHERE parent_id IS NULL AND deleted_at IS NULL").fetchall()
    else:
        rows = conn.execute("SELECT * FROM folders WHERE parent_id = ? AND deleted_at IS NULL", (parent_id,)).fetchall()
    if folder_sort_mode(conn, parent_id) == "name":
        return sorted(rows, key=lambda r: (natural_key(r["name"]), r["id"]))
    return sorted(rows, key=lambda r: (r["position"], natural_key(r["name"]), r["id"]))


def move_folder(conn, folder_id: int, to_index: int) -> None:
    row = conn.execute("SELECT parent_id FROM folders WHERE id = ?", (folder_id,)).fetchone()
    if row is None:
        raise FolderError("フォルダがありません")
    parent = row["parent_id"]
    ids = [r["id"] for r in ordered_folders(conn, parent)]
    ids.remove(folder_id)
    to_index = max(0, min(to_index, len(ids)))
    ids.insert(to_index, folder_id)
    conn.executemany("UPDATE folders SET position = ? WHERE id = ?", [(i, x) for i, x in enumerate(ids)])
    set_folder_sort_mode(conn, parent, "manual")


def move_item(conn, item_id: int, to_index: int) -> int:
    """フォルダ内で並び順を移動し、フォルダを手動並びに切り替える。フォルダ ID を返す。"""
    row = conn.execute("SELECT folder_id FROM items WHERE id = ?", (item_id,)).fetchone()
    if row is None:
        raise FolderError("画像がありません")
    fid = row["folder_id"]
    ids = [r["id"] for r in conn.execute(
        "SELECT id FROM items WHERE folder_id = ? AND deleted_at IS NULL ORDER BY position, id", (fid,))]
    ids.remove(item_id)
    to_index = max(0, min(to_index, len(ids)))
    ids.insert(to_index, item_id)
    conn.executemany("UPDATE items SET position = ? WHERE id = ?", [(i, x) for i, x in enumerate(ids)])
    conn.execute("UPDATE folders SET sort_mode = 'manual' WHERE id = ?", (fid,))
    return fid


def purge_items(conn, item_ids: list[int]) -> list[int]:
    """完全に消す。どのフォルダからも参照されなくなった画像の ID を返す。"""
    if not item_ids:
        return []
    marks = ",".join("?" * len(item_ids))
    image_ids = [r[0] for r in conn.execute(f"SELECT DISTINCT image_id FROM items WHERE id IN ({marks})", item_ids)]
    conn.execute(f"DELETE FROM items WHERE id IN ({marks})", item_ids)
    return unreferenced(conn, image_ids)


def purge_folder(conn, folder_id: int) -> list[int]:
    """フォルダと子フォルダを完全に消す。どこからも参照されなくなった画像の ID を返す。"""
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


# ---- 最近削除した項目 ----

TRASH_DAYS = 30


def trash_items(conn, item_ids: list[int]) -> None:
    if not item_ids:
        return
    marks = ",".join("?" * len(item_ids))
    conn.execute(f"UPDATE items SET deleted_at = ? WHERE id IN ({marks}) AND deleted_at IS NULL", [now(), *item_ids])


def trash_folder(conn, folder_id: int) -> None:
    t = now()
    conn.execute("UPDATE folders SET deleted_at = ? WHERE (id = ? OR parent_id = ?) AND deleted_at IS NULL",
                 (t, folder_id, folder_id))


def _unique_name(conn, name: str, parent_id: int | None, exclude: int) -> str:
    candidate, n = name, 1
    while (row := find_folder(conn, candidate, parent_id)) is not None and row["id"] != exclude:
        n += 1
        candidate = f"{name} (復元{'' if n == 2 else n - 1})"
    return candidate


def _undelete_folder(conn, folder_id: int) -> None:
    row = conn.execute("SELECT * FROM folders WHERE id = ?", (folder_id,)).fetchone()
    if row is None or row["deleted_at"] is None:
        return
    if row["parent_id"] is not None:
        _undelete_folder(conn, row["parent_id"])
    name = _unique_name(conn, row["name"], row["parent_id"], folder_id)
    conn.execute("UPDATE folders SET deleted_at = NULL, name = ? WHERE id = ?", (name, folder_id))


def restore_folder(conn, folder_id: int) -> None:
    _undelete_folder(conn, folder_id)
    for r in conn.execute("SELECT id FROM folders WHERE parent_id = ? AND deleted_at IS NOT NULL", (folder_id,)).fetchall():
        _undelete_folder(conn, r["id"])


def restore_items(conn, item_ids: list[int]) -> None:
    for iid in item_ids:
        row = conn.execute("SELECT folder_id FROM items WHERE id = ?", (iid,)).fetchone()
        if row is None:
            continue
        _undelete_folder(conn, row["folder_id"])
        conn.execute("UPDATE items SET deleted_at = NULL WHERE id = ?", (iid,))


def trash_contents(conn):
    """一番上の削除済みフォルダと、削除されていないフォルダの中の削除済み画像。"""
    folders = conn.execute(
        """SELECT f.* FROM folders f LEFT JOIN folders p ON p.id = f.parent_id
           WHERE f.deleted_at IS NOT NULL AND (f.parent_id IS NULL OR p.deleted_at IS NULL)
           ORDER BY f.deleted_at DESC"""
    ).fetchall()
    items = conn.execute(
        """SELECT it.*, f.name AS folder_name, im.width, im.height, im.ext
           FROM items it JOIN folders f ON f.id = it.folder_id JOIN images im ON im.id = it.image_id
           WHERE it.deleted_at IS NOT NULL AND f.deleted_at IS NULL
           ORDER BY it.deleted_at DESC, it.position"""
    ).fetchall()
    return folders, items


def expired(conn) -> tuple[list[int], list[int]]:
    """30日を過ぎたもの(フォルダ ID、画像の項目 ID)。"""
    limit = (datetime.now(timezone.utc) - timedelta(days=TRASH_DAYS)).isoformat(timespec="seconds")
    folders, items = trash_contents(conn)
    return ([f["id"] for f in folders if f["deleted_at"] < limit],
            [i["id"] for i in items if i["deleted_at"] < limit])


# ---- 移動 ----

def move_items_to(conn, item_ids: list[int], dest: int) -> int:
    """画像を別のフォルダへ移す。移動先にすでに同じ画像があれば、移動元から外すだけ。移した数を返す。"""
    target = conn.execute("SELECT * FROM folders WHERE id = ? AND deleted_at IS NULL", (dest,)).fetchone()
    if target is None:
        raise FolderError("移動先のフォルダがありません")
    pos = conn.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM items WHERE folder_id = ?", (dest,)).fetchone()[0]
    moved = 0
    for iid in item_ids:
        row = conn.execute("SELECT * FROM items WHERE id = ? AND deleted_at IS NULL", (iid,)).fetchone()
        if row is None or row["folder_id"] == dest:
            continue
        dup = conn.execute("SELECT id, deleted_at FROM items WHERE folder_id = ? AND image_id = ?",
                           (dest, row["image_id"])).fetchone()
        if dup is not None:
            conn.execute("UPDATE items SET deleted_at = NULL WHERE id = ?", (dup["id"],))
            conn.execute("DELETE FROM items WHERE id = ?", (iid,))
        else:
            conn.execute("UPDATE items SET folder_id = ?, position = ? WHERE id = ?", (dest, pos, iid))
            pos += 1
        moved += 1
    if target["sort_mode"] == "name":
        renumber_by_name(conn, dest)
    return moved


def move_folder_to(conn, folder_id: int, parent_id: int | None) -> None:
    row = conn.execute("SELECT * FROM folders WHERE id = ? AND deleted_at IS NULL", (folder_id,)).fetchone()
    if row is None:
        raise FolderError("フォルダがありません")
    if parent_id == folder_id:
        raise FolderError("自分自身の中には移動できません")
    if parent_id is not None:
        parent = conn.execute("SELECT * FROM folders WHERE id = ? AND deleted_at IS NULL", (parent_id,)).fetchone()
        if parent is None:
            raise FolderError("移動先のフォルダがありません")
        if parent["parent_id"] is not None:
            raise FolderError("フォルダは2段までです")
        has_children = conn.execute(
            "SELECT 1 FROM folders WHERE parent_id = ? AND deleted_at IS NULL LIMIT 1", (folder_id,)).fetchone()
        if has_children:
            raise FolderError("子フォルダを持つフォルダは、ほかのフォルダの中に入れられません(2段まで)")
    same = find_folder(conn, row["name"], parent_id)
    if same is not None and same["id"] != folder_id:
        raise FolderError("移動先に同じ名前のフォルダがあります")
    if parent_id is None:
        pos = conn.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM folders WHERE parent_id IS NULL").fetchone()[0]
    else:
        pos = conn.execute("SELECT COALESCE(MAX(position), -1) + 1 FROM folders WHERE parent_id = ?", (parent_id,)).fetchone()[0]
    conn.execute("UPDATE folders SET parent_id = ?, position = ? WHERE id = ?", (parent_id, pos, folder_id))


def unreferenced(conn, image_ids: list[int]) -> list[int]:
    return [i for i in image_ids
            if conn.execute("SELECT 1 FROM items WHERE image_id = ? LIMIT 1", (i,)).fetchone() is None]


# ---- folders ----

class FolderError(Exception):
    pass


def find_folder(conn, name: str, parent_id: int | None):
    if parent_id is None:
        return conn.execute(
            "SELECT * FROM folders WHERE parent_id IS NULL AND name = ? AND deleted_at IS NULL", (name,)
        ).fetchone()
    return conn.execute(
        "SELECT * FROM folders WHERE parent_id = ? AND name = ? AND deleted_at IS NULL", (parent_id, name)
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
        "SELECT id, deleted_at FROM items WHERE folder_id = ? AND image_id = ?", (folder_id, image_id)
    ).fetchone()
    if exists is not None:
        if exists["deleted_at"] is None:
            return None
        # 最近削除した項目に入っていた同じ画像は、そのまま戻す
        conn.execute("UPDATE items SET deleted_at = NULL WHERE id = ?", (exists["id"],))
        return exists["id"]
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
