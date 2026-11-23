# View Fans server

FastAPI + SQLite。`/` で Web 版(viewfans/web)を配信し、API は Authorization ヘッダーか Web 版の Cookie で認証する。データは `/srv/viewfans`(環境変数 `VIEWFANS_DATA` で変更可)。

## API(`/api/health` 以外は `Authorization: Bearer <トークン>` が必要)

| メソッド | パス | 内容 |
|---|---|---|
| GET | /api/health | 死活確認 |
| GET | /api/folders?parent_id= | フォルダ一覧(省略で最上位) |
| GET | /api/folders/{id} | フォルダ情報 |
| POST | /api/folders | フォルダ作成 `{"name": "...", "parent_id": null}`(2段まで) |
| GET | /api/folders/{id}/items?offset=&limit= | フォルダ内の画像(並び順) |
| POST | /api/folders/{id}/items | 画像アップロード(multipart の `file`) |
| GET | /api/images/{id}/thumb | サムネイル(長辺 600px の JPEG) |
| GET | /api/images/{id}/medium | 中間サイズ(長辺 1600px、初回要求時に生成) |
| GET | /api/images/{id}/original | 元画像 |
| DELETE | /api/folders/{id} | フォルダを子フォルダごと「最近削除した項目」へ |
| POST | /api/folders/{id}/sort | 並び順の切り替え `{"mode": "name"}`(ファイル名順に並べ直す)/ `"manual"` |
| PATCH | /api/items/{id} | 表示位置 `{"crop_x", "crop_y", "crop_zoom"}` |
| POST | /api/items/{id}/move | 並べ替え `{"to_index"}`(フォルダは手動並びになる) |
| POST | /api/items/delete | 画像を「最近削除した項目」へ `{"ids": [...]}` |
| GET | /api/trash | 最近削除した項目(30日を過ぎたものはこのとき完全に削除) |
| POST | /api/trash/restore | 復元 `{"folder_ids": [], "item_ids": []}` |
| POST | /api/trash/purge | 完全に削除 `{"folder_ids": [], "item_ids": []}`(参照されなくなった画像はファイルごと消す) |
| POST | /api/trash/empty | 最近削除した項目をすべて完全に削除 |
| POST | /api/items/move-to | 画像を別のフォルダへ移動 `{"ids": [], "folder_id"}` |
| POST | /api/folders/{id}/move-to | フォルダを移動 `{"parent_id": null}`(2段まで) |
| POST | /api/login | Web 版のログイン `{"token"}`(Cookie を発行) |
| POST | /api/logout | Web 版のログアウト |
| GET | /api/items/{id}/download | 元画像を元のファイル名でダウンロード |
| POST | /api/items/zip | 選択した画像を zip でダウンロード(フォーム `ids=1,2,3`、`name`) |
| GET | /api/stats | 枚数・フォルダ数・ディスク使用量 |
| POST | /api/folders/{id}/move | フォルダの並べ替え `{"to_index"}`(同じ階層は手動並びになる) |
| POST | /api/folders/sort-children | フォルダの並びを名前順に戻す `{"parent_id": null, "mode": "name"}` |
| PATCH | /api/folders/{id} | 名前変更 `{"name"}`、表紙設定 `{"cover_image_id"}`、表紙を自動に戻す `{"clear_cover": true}`、表紙の表示位置 `{"cover_crop_x", "cover_crop_y", "cover_crop_zoom"}` |

## 管理コマンド

```
viewfans init
viewfans import <取り込み元> [--dry-run] [--workers 4]
viewfans medium [--workers 4]
viewfans token create <名前>
viewfans token list
viewfans token revoke <名前>
```

取り込み元の形: `<取り込み元>/<まとまり>/<親>/<画像>` または `<取り込み元>/<まとまり>/<親>/<子>/<画像>`。
`<まとまり>` は zip ごとの展開先など。フォルダ名には使わず、同じ親・子の名前はまとめる。
同じ画像はハッシュで判定して1枚にする。何度実行しても、取り込み済みの画像は重複として飛ばす。
