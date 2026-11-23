#!/usr/bin/env bash
# push して、サーバーの更新を知らせ、iPad アプリが変わっていればビルド完了を待って .ipa を受け渡す。
# 使い方: ~/src/viewfans で ./scripts/deploy.sh
set -euo pipefail

WIN_IP="${WIN_IP:-10.0.1.100}"   # .ipa を取りに来るノートパソコン
PORT="${PORT:-8080}"
OUT="$HOME/viewfans-ipa"

cd "$(git rev-parse --show-toplevel)"
before="$(git rev-parse '@{u}')"
git push
head="$(git rev-parse HEAD)"
changed="$(git diff --name-only "$before" "$head")"

if [ -z "$changed" ]; then
    echo "送る変更はありません"
    exit 0
fi

if grep -q '^server/' <<<"$changed"; then
    echo "● サーバー: 2分以内に sys-vfan01 が自動で更新・再起動します"
fi

if ! grep -q -e '^ios/' -e '^\.github/workflows/ios\.yml' <<<"$changed"; then
    echo "● iPad アプリ: 変更なし"
    exit 0
fi

echo "● iPad アプリ: ビルドの開始を待っています…"
run=""
for _ in $(seq 1 30); do
    run="$(gh run list --workflow ios --commit "$head" --json databaseId --jq '.[0].databaseId // empty')"
    [ -n "$run" ] && break
    sleep 5
done
[ -n "$run" ] || { echo "ビルドが見つかりません(gh run list で確認してください)"; exit 1; }

if ! gh run watch "$run" --exit-status; then
    echo "ビルド失敗。エラー部分をクリップボードに入れました"
    gh run view "$run" --log-failed | tail -60 | wl-copy
    exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT/ViewFans.ipa"
gh run download "$run" -n ViewFans-ipa -D "$OUT"

ip="$(ip -4 -o route get "$WIN_IP" | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
cmd="curl.exe -o \"\$env:USERPROFILE\\Downloads\\ViewFans.ipa\" http://$ip:$PORT/ViewFans.ipa"
echo
echo "● ノートパソコンの PowerShell で実行してください(クリップボードにも入れました):"
echo "  $cmd"
printf '%s' "$cmd" | wl-copy
python3 "$(dirname "$0")/serve_once.py" "$OUT/ViewFans.ipa" "$PORT" "$WIN_IP"
echo "● 受け渡し完了。Sideloadly で上書きインストールしてください"
