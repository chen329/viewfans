"""画像の保存とサムネイル生成。DB には触らない(並列処理で使うため)。"""
import hashlib
import os
import shutil
import tempfile
from pathlib import Path

from PIL import Image, ImageOps

from . import config

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:  # HEIC を使わない環境でも動くように
    pass

Image.MAX_IMAGE_PIXELS = 300_000_000


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def shard(base: Path, sha: str, ext: str) -> Path:
    return base / sha[0:2] / sha[2:4] / f"{sha}.{ext}"


def original_path(sha: str, ext: str) -> Path:
    return shard(config.ORIGINALS_DIR, sha, ext)


def thumb_path(sha: str) -> Path:
    return shard(config.THUMBS_DIR, sha, "jpg")


def medium_path(sha: str) -> Path:
    return shard(config.MEDIUM_DIR, sha, "jpg")


def normalize_ext(name: str) -> str | None:
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return config.SUPPORTED_EXT.get(ext)


def make_thumb(src: Path, dst: Path, long_edge: int = config.THUMB_LONG_EDGE,
               quality: int = config.THUMB_QUALITY) -> tuple[int, int]:
    """縮小版を作り、向きを補正した元画像の幅・高さを返す。"""
    with Image.open(src) as im:
        im.draft("RGB", (long_edge * 2, long_edge * 2))
        im = ImageOps.exif_transpose(im)
        # draft で縮小されることがあるので、元の大きさは別に取り直す
        width, height = _real_size(src)
        if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
            im = im.convert("RGBA")
            bg = Image.new("RGB", im.size, (0, 0, 0))
            bg.paste(im, mask=im.getchannel("A"))
            im = bg
        else:
            im = im.convert("RGB")
        im.thumbnail((long_edge, long_edge), Image.LANCZOS)
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(f"{dst.stem}.{os.getpid()}.tmp")
        im.save(tmp, "JPEG", quality=quality, optimize=True)
        os.replace(tmp, dst)
    return width, height


def ensure_medium(sha: str, ext: str) -> Path:
    """中間サイズ(長辺1600px)を初回の要求時に作る。"""
    dst = medium_path(sha)
    if not dst.exists():
        make_thumb(original_path(sha, ext), dst, config.MEDIUM_LONG_EDGE, config.MEDIUM_QUALITY)
    return dst


def medium_job(args: tuple[str, str]) -> str | None:
    """一括生成用。失敗したらエラー文を返す。"""
    sha, ext = args
    try:
        ensure_medium(sha, ext)
        return None
    except Exception as e:
        return f"{sha}: {type(e).__name__}: {e}"


def _real_size(src: Path) -> tuple[int, int]:
    with Image.open(src) as im:
        w, h = im.size
        try:
            orientation = im.getexif().get(0x0112, 1)
        except Exception:
            orientation = 1
    if orientation in (5, 6, 7, 8):
        w, h = h, w
    return w, h


def store_original(src: Path, sha: str, ext: str, move: bool = False) -> Path:
    """originals/ に置く。同じディスクならハードリンク、だめならコピー。"""
    dst = original_path(sha, ext)
    if dst.exists():
        if move:
            src.unlink()
        return dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    if move:
        shutil.move(src, dst)
        return dst
    try:
        os.link(src, dst)
    except OSError:
        fd, tmp = tempfile.mkstemp(dir=dst.parent)
        os.close(fd)
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
    return dst


def process_file(src: str) -> dict:
    """並列処理用。ハッシュ計算・保存・サムネイル生成をまとめて行う。"""
    path = Path(src)
    ext = normalize_ext(path.name)
    if ext is None:
        return {"src": src, "error": "対応していない形式"}
    try:
        sha = sha256_file(path)
        thumb = thumb_path(sha)
        width, height = make_thumb(path, thumb) if not thumb.exists() else _real_size(path)
        store_original(path, sha, ext)
        ensure_medium(sha, ext)
        return {
            "src": src,
            "sha256": sha,
            "ext": ext,
            "width": width,
            "height": height,
            "bytes": path.stat().st_size,
        }
    except Exception as e:  # 壊れた画像などは記録して飛ばす
        return {"src": src, "error": f"{type(e).__name__}: {e}"}
