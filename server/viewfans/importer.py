"""一括取り込み。

取り込み元の形:
    <root>/<まとまり>/<親フォルダ>/<画像>
    <root>/<まとまり>/<親フォルダ>/<子フォルダ>/<画像>

<まとまり> は zip ごとの展開先など、取り込みの単位。フォルダ名には使わない。
複数のまとまりに同じ親・子フォルダ名があれば、1つのフォルダにまとめる。
同じ画像(ハッシュが同じ)は1枚として扱う。
"""
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from . import db, storage


def natural_key(s: str):
    return db.natural_key(s)


def plan(root: Path):
    """(親名, 子名 or None, ファイルパス) の一覧と、取り込めないものの一覧を返す。"""
    entries, skipped = [], []
    for batch in sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: natural_key(p.name)):
        for path in sorted(batch.rglob("*"), key=lambda p: [natural_key(x) for x in p.relative_to(batch).parts]):
            if not path.is_file():
                continue
            parts = path.relative_to(batch).parts
            if storage.normalize_ext(path.name) is None:
                skipped.append((path, "対応していない形式"))
            elif len(parts) == 2:
                entries.append((parts[0], None, path))
            elif len(parts) == 3:
                entries.append((parts[0], parts[1], path))
            else:
                skipped.append((path, "フォルダの深さが対応外"))
    for p in root.iterdir():
        if p.is_file():
            skipped.append((p, "まとまりのフォルダの外にある"))
    return entries, skipped


def run(root: Path, workers: int = 4, dry_run: bool = False) -> int:
    entries, skipped = plan(root)
    print(f"対象 {len(entries)} 件、対象外 {len(skipped)} 件")
    for path, reason in skipped:
        print(f"  対象外: {path} ({reason})")
    if dry_run:
        folders = {}
        for parent, child, _ in entries:
            key = parent if child is None else f"{parent}/{child}"
            folders[key] = folders.get(key, 0) + 1
        for key in sorted(folders, key=natural_key):
            print(f"  {key}: {folders[key]} 枚")
        return 0

    conn = db.connect()
    db.init(conn)
    folder_cache: dict[tuple[str, str | None], int] = {}

    def folder_id(parent: str, child: str | None) -> int:
        key = (parent, child)
        if key not in folder_cache:
            pid = db.get_or_create_folder(conn, parent, None)
            folder_cache[key] = pid if child is None else db.get_or_create_folder(conn, child, pid)
        return folder_cache[key]

    added = dup = failed = 0
    touched: set[int] = set()
    srcs = [str(p) for _, _, p in entries]
    with ProcessPoolExecutor(max_workers=workers) as ex:
        # 結果は入力順で返るので、並び順(自然順)が保たれる
        for i, ((parent, child, path), res) in enumerate(zip(entries, ex.map(storage.process_file, srcs, chunksize=16)), 1):
            if "error" in res:
                failed += 1
                print(f"  失敗: {path} ({res['error']})", file=sys.stderr)
                continue
            img = db.find_image(conn, res["sha256"])
            image_id = img["id"] if img else db.insert_image(
                conn, res["sha256"], res["ext"], res["width"], res["height"], res["bytes"]
            )
            fid = folder_id(parent, child)
            touched.add(fid)
            if db.add_item(conn, fid, image_id, path.name, renumber=False) is None:
                dup += 1
            else:
                added += 1
            if i % 500 == 0:
                conn.commit()
                print(f"  {i}/{len(entries)}")
    for fid in touched:
        if conn.execute("SELECT sort_mode FROM folders WHERE id = ?", (fid,)).fetchone()[0] == "name":
            db.renumber_by_name(conn, fid)
    conn.commit()
    print(f"追加 {added} 件、重複 {dup} 件、失敗 {failed} 件")
    return 1 if failed else 0
