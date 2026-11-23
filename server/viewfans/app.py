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
    }


@app.get("/api/health")
def health():
    return {"ok": True}


@app.get("/api/folders", dependencies=[Depends(auth)])
def list_folders(parent_id: int | None = None, c=Depends(conn)):
    if parent_id is None:
        rows = c.execute("SELECT * FROM folders WHERE parent_id IS NULL ORDER BY position").fetchall()
    else:
        rows = c.execute("SELECT * FROM folders WHERE parent_id = ? ORDER BY position", (parent_id,)).fetchall()
    return [folder_dict(c, r) for r in rows]


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


@app.patch("/api/folders/{folder_id}", dependencies=[Depends(auth)])
def patch_folder(folder_id: int, body: FolderPatch, c=Depends(conn)):
    if c.execute("SELECT 1 FROM folders WHERE id = ?", (folder_id,)).fetchone() is None:
        raise HTTPException(404, "フォルダがありません")
    try:
        if body.name is not None:
            db.rename_folder(c, folder_id, body.name)
    except db.FolderError as e:
        raise HTTPException(400, str(e))
    if body.clear_cover:
        c.execute("UPDATE folders SET cover_image_id = NULL WHERE id = ?", (folder_id,))
    elif body.cover_image_id is not None:
        _image(c, body.cover_image_id)
        c.execute("UPDATE folders SET cover_image_id = ? WHERE id = ?", (body.cover_image_id, folder_id))
    c.commit()
    return get_folder(folder_id, c)


@app.get("/api/folders/{folder_id}/items", dependencies=[Depends(auth)])
def list_items(
    folder_id: int,
    offset: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=5000),
    c=Depends(conn),
):
    total = c.execute("SELECT COUNT(*) FROM items WHERE folder_id = ?", (folder_id,)).fetchone()[0]
    rows = c.execute(
        """SELECT it.id, it.image_id, it.position, it.crop_x, it.crop_y,
                  im.width, im.height, im.ext
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
