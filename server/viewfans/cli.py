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


if __name__ == "__main__":
    sys.exit(main())
