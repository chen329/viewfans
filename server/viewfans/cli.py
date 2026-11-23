"""管理コマンド。

    python -m viewfans.cli init
    python -m viewfans.cli import /srv/viewfans/import [--dry-run] [--workers 4]
    python -m viewfans.cli token create <名前>
    python -m viewfans.cli token list
    python -m viewfans.cli token revoke <名前>
"""
import argparse
import secrets
import sys
from pathlib import Path

from . import db, importer


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="viewfans")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="データベースを作る")

    p_imp = sub.add_parser("import", help="一括取り込み")
    p_imp.add_argument("root", type=Path)
    p_imp.add_argument("--dry-run", action="store_true", help="取り込まずにフォルダごとの枚数だけ表示")
    p_imp.add_argument("--workers", type=int, default=4)

    p_med = sub.add_parser("medium", help="中間サイズ(長辺1600px)をまだ無い画像ぶん作る")
    p_med.add_argument("--workers", type=int, default=4)

    p_tok = sub.add_parser("token", help="端末トークンの管理")
    tsub = p_tok.add_subparsers(dest="tcmd", required=True)
    t_create = tsub.add_parser("create")
    t_create.add_argument("name")
    tsub.add_parser("list")
    t_revoke = tsub.add_parser("revoke")
    t_revoke.add_argument("name")

    a = ap.parse_args(argv)

    if a.cmd == "import":
        return importer.run(a.root, workers=a.workers, dry_run=a.dry_run)
    if a.cmd == "medium":
        return make_all_medium(a.workers)

    conn = db.connect()
    db.init(conn)

    if a.cmd == "init":
        print("初期化しました")
    elif a.tcmd == "create":
        token = secrets.token_urlsafe(32)
        conn.execute(
            "INSERT INTO tokens(name, token_hash, created_at) VALUES (?, ?, ?)",
            (a.name, db.hash_token(token), db.now()),
        )
        conn.commit()
        print(token)
    elif a.tcmd == "list":
        for r in conn.execute("SELECT name, created_at, last_used_at FROM tokens ORDER BY id"):
            print(f"{r['name']}\t作成 {r['created_at']}\t最終使用 {r['last_used_at'] or '-'}")
    elif a.tcmd == "revoke":
        n = conn.execute("DELETE FROM tokens WHERE name = ?", (a.name,)).rowcount
        conn.commit()
        print(f"{n} 件削除しました")
    return 0


def make_all_medium(workers: int) -> int:
    from concurrent.futures import ProcessPoolExecutor

    from . import storage

    conn = db.connect()
    db.init(conn)
    rows = [(r["sha256"], r["ext"]) for r in conn.execute("SELECT sha256, ext FROM images ORDER BY id")]
    todo = [r for r in rows if not storage.medium_path(r[0]).exists()]
    print(f"全 {len(rows)} 枚、作成するもの {len(todo)} 枚")
    failed = 0
    with ProcessPoolExecutor(max_workers=workers) as ex:
        for i, err in enumerate(ex.map(storage.medium_job, todo, chunksize=16), 1):
            if err:
                failed += 1
                print(f"  失敗: {err}", file=sys.stderr)
            if i % 500 == 0:
                print(f"  {i}/{len(todo)}")
    print(f"作成 {len(todo) - failed} 枚、失敗 {failed} 枚")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
