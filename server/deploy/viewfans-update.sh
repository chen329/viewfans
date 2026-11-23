#!/bin/sh
# GitHub に新しいコミットがあれば取り込み、server/ が変わっていればサーバーを再起動する(root で実行)。
set -eu
cd /opt/viewfans
git fetch -q origin main
old="$(git rev-parse HEAD)"
new="$(git rev-parse origin/main)"
[ "$old" = "$new" ] && exit 0

git merge -q --ff-only origin/main
changed="$(git diff --name-only "$old" "$new")"
echo "更新: $old -> $new"

if echo "$changed" | grep -q '^server/pyproject\.toml$'; then
    /opt/viewfans/venv/bin/pip install -q -e /opt/viewfans/server
fi
if echo "$changed" | grep -q '^server/deploy/viewfans\.service$'; then
    cp /opt/viewfans/server/deploy/viewfans.service /etc/systemd/system/
    systemctl daemon-reload
fi
if echo "$changed" | grep -q '^server/'; then
    systemctl restart viewfans
    echo "viewfans を再起動しました"
fi
