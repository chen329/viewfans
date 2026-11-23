import shutil
import tempfile
from pathlib import Path

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from . import config, db, storage

app = FastAPI(title="View Fans")

_init = db.connect()
db.init(_init)
_init.close()


def conn():
    c = db.connect()
    try:
        yield c
    finally:
        c.close()


def auth(authorization: str | None = Header(default=None), c=Depends(conn)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "トークンがありません")
    if not db.check_token(c, authorization[7:]):
        raise HTTPException(401, "トークンが無効です")


IMMUTABLE = {"Cache-Control": "private, max-age=31536000, immutable"}


def folder_dict(c, row) -> dict:
    fid = row["id"]
    count = c.execute("SELECT COUNT(*) FROM items WHERE folder_id = ?", (fid,)).fetchone()[0]
    children = c.execute("SELECT COUNT(*) FROM folders WHERE parent_id = ?", (fid,)).fetchone()[0]
    cover = (row["cover_image_id"],) if row["cover_image_id"] is not None else None
    if cover is None:
        cover = c.execute(
            """SELECT image_id FROM items WHERE folder_id = ?
               ORDER BY position LIMIT 1""",
            (fid,),
        ).fetchone()
    if cover is None:
        cover = c.execute(
            """SELECT i.image_id FROM items i JOIN folders f ON f.id = i.folder_id
               WHERE f.parent_id = ? ORDER BY f.position, i.position LIMIT 1""",
            (fid,),
        ).fetchone()
    return {
        "id": fid,
        "parent_id": row["parent_id"],
        "name": row["name"],
        "position": row["position"],
        "item_count": count,
        "child_count": children,
        "cover_image_id": cover[0] if cover else None,
        "cover_is_custom": row["cover_image_id"] is not None,
        "sort_mode": row["sort_mode"],
        "child_sort_mode": db.folder_sort_mode(c, fid),
        "cover_crop_x": row["cover_crop_x"],
        "cover_crop_y": row["cover_crop_y"],
        "cover_crop_zoom": row["cover_crop_zoom"],
    }


@app.get("/api/health")
def health():
    return {"ok": True}


class MoveBody(BaseModel):
    to_index: int


@app.get("/api/folders", dependencies=[Depends(auth)])
def list_folders(parent_id: int | None = None, c=Depends(conn)):
    return [folder_dict(c, r) for r in db.ordered_folders(c, parent_id)]


class FolderSortBody(BaseModel):
    parent_id: int | None = None
    mode: str


@app.post("/api/folders/sort-children", dependencies=[Depends(auth)])
def sort_children(body: FolderSortBody, c=Depends(conn)):
    if body.mode not in ("name", "manual"):
        raise HTTPException(400, "mode は name か manual です")
    db.set_folder_sort_mode(c, body.parent_id, body.mode)
    c.commit()
    return list_folders(body.parent_id, c)


@app.post("/api/folders/{folder_id}/move", dependencies=[Depends(auth)])
def move_folder(folder_id: int, body: MoveBody, c=Depends(conn)):
    try:
        db.move_folder(c, folder_id, body.to_index)
    except db.FolderError as e:
        raise HTTPException(404, str(e))
    c.commit()
    return {"ok": True}


@app.get("/api/folders/{folder_id}", dependencies=[Depends(auth)])
def get_folder(folder_id: int, c=Depends(conn)):
    row = c.execute("SELECT * FROM folders WHERE id = ?", (folder_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "フォルダがありません")
    return folder_dict(c, row)


class NewFolder(BaseModel):
    name: str
    parent_id: int | None = None


@app.post("/api/folders", dependencies=[Depends(auth)], status_code=201)
def create_folder(body: NewFolder, c=Depends(conn)):
    try:
        fid = db.create_folder(c, body.name, body.parent_id)
    except db.FolderError as e:
        raise HTTPException(400, str(e))
    c.commit()
    return get_folder(fid, c)


class FolderPatch(BaseModel):
    name: str | None = None
    cover_image_id: int | None = None
    clear_cover: bool = False
    cover_crop_x: float | None = None
    cover_crop_y: float | None = None
    cover_crop_zoom: float | None = None


@app.patch("/api/folders/{folder_id}", dependencies=[Depends(auth)])
def patch_folder(folder_id: int, body: FolderPatch, c=Depends(conn)):
    if c.execute("SELECT 1 FROM folders WHERE id = ?", (folder_id,)).fetchone() is None:
        raise HTTPException(404, "フォルダがありません")
    try:
        if body.name is not None:
            db.rename_folder(c, folder_id, body.name)
    except db.FolderError as e:
        raise HTTPException(400, str(e))
    reset_crop = "cover_crop_x = 0.5, cover_crop_y = 0.5, cover_crop_zoom = 1.0"
    if body.clear_cover:
        c.execute(f"UPDATE folders SET cover_image_id = NULL, {reset_crop} WHERE id = ?", (folder_id,))
    elif body.cover_image_id is not None:
        _image(c, body.cover_image_id)
        c.execute(f"UPDATE folders SET cover_image_id = ?, {reset_crop} WHERE id = ?", (body.cover_image_id, folder_id))
    if body.cover_crop_x is not None:
        c.execute("UPDATE folders SET cover_crop_x = ? WHERE id = ?", (min(max(body.cover_crop_x, 0.0), 1.0), folder_id))
    if body.cover_crop_y is not None:
        c.execute("UPDATE folders SET cover_crop_y = ? WHERE id = ?", (min(max(body.cover_crop_y, 0.0), 1.0), folder_id))
    if body.cover_crop_zoom is not None:
        c.execute("UPDATE folders SET cover_crop_zoom = ? WHERE id = ?", (min(max(body.cover_crop_zoom, 1.0), 8.0), folder_id))
    c.commit()
    return get_folder(folder_id, c)


@app.delete("/api/folders/{folder_id}", dependencies=[Depends(auth)])
def delete_folder(folder_id: int, c=Depends(conn)):
    if c.execute("SELECT 1 FROM folders WHERE id = ?", (folder_id,)).fetchone() is None:
        raise HTTPException(404, "フォルダがありません")
    gone = db.delete_folder(c, folder_id)
    removed = _purge_images(c, gone)
    c.commit()
    return {"deleted_images": removed}


class SortBody(BaseModel):
    mode: str


@app.post("/api/folders/{folder_id}/sort", dependencies=[Depends(auth)])
def sort_folder(folder_id: int, body: SortBody, c=Depends(conn)):
    if body.mode not in ("name", "manual"):
        raise HTTPException(400, "mode は name か manual です")
    if c.execute("SELECT 1 FROM folders WHERE id = ?", (folder_id,)).fetchone() is None:
        raise HTTPException(404, "フォルダがありません")
    db.set_sort_mode(c, folder_id, body.mode)
    c.commit()
    return get_folder(folder_id, c)


class ItemPatch(BaseModel):
    crop_x: float | None = None
    crop_y: float | None = None
    crop_zoom: float | None = None


@app.patch("/api/items/{item_id}", dependencies=[Depends(auth)])
def patch_item(item_id: int, body: ItemPatch, c=Depends(conn)):
    if c.execute("SELECT 1 FROM items WHERE id = ?", (item_id,)).fetchone() is None:
        raise HTTPException(404, "画像がありません")
    if body.crop_x is not None:
        c.execute("UPDATE items SET crop_x = ? WHERE id = ?", (min(max(body.crop_x, 0.0), 1.0), item_id))
    if body.crop_y is not None:
        c.execute("UPDATE items SET crop_y = ? WHERE id = ?", (min(max(body.crop_y, 0.0), 1.0), item_id))
    if body.crop_zoom is not None:
        c.execute("UPDATE items SET crop_zoom = ? WHERE id = ?", (min(max(body.crop_zoom, 1.0), 8.0), item_id))
    c.commit()
    return {"ok": True}


@app.post("/api/items/{item_id}/move", dependencies=[Depends(auth)])
def move_item(item_id: int, body: MoveBody, c=Depends(conn)):
    try:
        fid = db.move_item(c, item_id, body.to_index)
    except db.FolderError as e:
        raise HTTPException(404, str(e))
    c.commit()
    return get_folder(fid, c)


class DeleteItems(BaseModel):
    ids: list[int]


@app.post("/api/items/delete", dependencies=[Depends(auth)])
def delete_items(body: DeleteItems, c=Depends(conn)):
    gone = db.delete_items(c, body.ids)
    removed = _purge_images(c, gone)
    c.commit()
    return {"deleted_images": removed}


def _purge_images(c, image_ids: list[int]) -> int:
    """どこからも参照されない画像を、ファイルごと完全に消す。"""
    for iid in image_ids:
        row = c.execute("SELECT sha256, ext FROM images WHERE id = ?", (iid,)).fetchone()
        if row is None:
            continue
        c.execute("UPDATE folders SET cover_image_id = NULL WHERE cover_image_id = ?", (iid,))
        c.execute("DELETE FROM images WHERE id = ?", (iid,))
        storage.remove_files(row["sha256"], row["ext"])
    return len(image_ids)


@app.get("/api/folders/{folder_id}/items", dependencies=[Depends(auth)])
def list_items(
    folder_id: int,
    offset: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=5000),
    c=Depends(conn),
):
    total = c.execute("SELECT COUNT(*) FROM items WHERE folder_id = ?", (folder_id,)).fetchone()[0]
    rows = c.execute(
        """SELECT it.id, it.image_id, it.position, it.crop_x, it.crop_y, it.crop_zoom,
                  it.original_name, im.width, im.height, im.ext
           FROM items it JOIN images im ON im.id = it.image_id
           WHERE it.folder_id = ? ORDER BY it.position LIMIT ? OFFSET ?""",
        (folder_id, limit, offset),
    ).fetchall()
    return {"total": total, "offset": offset, "items": [dict(r) for r in rows]}


def _image(c, image_id: int):
    row = c.execute("SELECT * FROM images WHERE id = ?", (image_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "画像がありません")
    return row


@app.get("/api/images/{image_id}/thumb", dependencies=[Depends(auth)])
def get_thumb(image_id: int, c=Depends(conn)):
    row = _image(c, image_id)
    return FileResponse(storage.thumb_path(row["sha256"]), media_type="image/jpeg", headers=IMMUTABLE)


@app.get("/api/images/{image_id}/medium", dependencies=[Depends(auth)])
def get_medium(image_id: int, c=Depends(conn)):
    row = _image(c, image_id)
    path = storage.ensure_medium(row["sha256"], row["ext"])
    return FileResponse(path, media_type="image/jpeg", headers=IMMUTABLE)


@app.get("/api/images/{image_id}/original", dependencies=[Depends(auth)])
def get_original(image_id: int, c=Depends(conn)):
    row = _image(c, image_id)
    return FileResponse(
        storage.original_path(row["sha256"], row["ext"]),
        media_type=config.MEDIA_TYPES[row["ext"]],
        headers=IMMUTABLE,
    )


@app.post("/api/folders/{folder_id}/items", dependencies=[Depends(auth)], status_code=201)
def upload(folder_id: int, file: UploadFile = File(...), c=Depends(conn)):
    if c.execute("SELECT 1 FROM folders WHERE id = ?", (folder_id,)).fetchone() is None:
        raise HTTPException(404, "フォルダがありません")
    name = file.filename or "upload"
    if storage.normalize_ext(name) is None:
        raise HTTPException(400, "対応していない形式です")
    tmp_dir = config.DATA_DIR / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=tmp_dir, suffix=Path(name).suffix, delete=False) as tmp:
        shutil.copyfileobj(file.file, tmp)
    tmp_path = Path(tmp.name)
    try:
        res = storage.process_file(str(tmp_path))
    finally:
        tmp_path.unlink(missing_ok=True)
    if "error" in res:
        raise HTTPException(400, f"画像を読めません: {res['error']}")
    img = db.find_image(c, res["sha256"])
    image_id = img["id"] if img else db.insert_image(
        c, res["sha256"], res["ext"], res["width"], res["height"], res["bytes"]
    )
    item_id = db.add_item(c, folder_id, image_id, name)
    c.commit()
    return {"image_id": image_id, "item_id": item_id, "duplicate": item_id is None}
