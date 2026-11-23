"use strict";
// View Fans の Web 版(iPhone・PC 用の簡易ビューワー)。閲覧・ダウンロード・アップロード。

const $ = (id) => document.getElementById(id);
const state = { folder: null, folders: [], items: [], selecting: false, selected: new Set(), viewer: -1 };

async function api(path, opts = {}) {
  const res = await fetch(path, { credentials: "same-origin", ...opts });
  if (res.status === 401) { showLogin(); throw new Error("ログインが必要です"); }
  if (!res.ok) {
    let msg = `HTTP ${res.status}`;
    try { msg = (await res.json()).detail || msg; } catch (_) {}
    throw new Error(msg);
  }
  return res.json();
}

// ---- ログイン ----

function showLogin() {
  $("app").hidden = true;
  $("login").hidden = false;
  $("token").focus();
}

$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("login-error").textContent = "";
  try {
    await api("/api/login", { method: "POST", headers: { "Content-Type": "application/json" },
                              body: JSON.stringify({ token: $("token").value }) });
    $("token").value = "";
    $("login").hidden = true;
    route();
  } catch (err) {
    $("login-error").textContent = err.message;
  }
});

$("logout").onclick = async () => {
  await fetch("/api/logout", { method: "POST" });
  showLogin();
};

// ---- 画面の切り替え(#/ が最上位、#/f/<id> がフォルダ) ----

window.addEventListener("hashchange", route);

async function route() {
  const m = location.hash.match(/^#\/f\/(\d+)/);
  const id = m ? Number(m[1]) : null;
  closeViewer();
  setSelecting(false);
  try {
    const [folders, folder] = await Promise.all([
      api("/api/folders" + (id ? `?parent_id=${id}` : "")),
      id ? api(`/api/folders/${id}`) : Promise.resolve(null),
    ]);
    let items = [];
    if (id) {
      for (let offset = 0; ; ) {
        const page = await api(`/api/folders/${id}/items?offset=${offset}&limit=1000`);
        items = items.concat(page.items);
        offset += page.items.length;
        if (!page.items.length || offset >= page.total) break;
      }
    }
    Object.assign(state, { folder, folders, items });
    $("login").hidden = true;
    $("app").hidden = false;
    render();
  } catch (err) {
    if ($("login").hidden) alert(err.message);
  }
}

// ---- 列数(フォルダごと・縦横別に保存) ----

function colsKey() {
  const orient = innerWidth > innerHeight ? "landscape" : "portrait";
  return `cols.${state.folder ? state.folder.id : "root"}.${orient}`;
}
function getCols() {
  const v = Number(localStorage.getItem(colsKey()));
  if (v) return v;
  return innerWidth > innerHeight ? (innerWidth > 900 ? 8 : 6) : (innerWidth > 600 ? 5 : 3);
}
function setCols(n) {
  n = Math.min(20, Math.max(1, n));
  localStorage.setItem(colsKey(), n);
  applyCols();
}
function applyCols() {
  const n = getCols();
  document.documentElement.style.setProperty("--cols", n);
  $("cols").value = n;
  // 大きく表示するときは中間サイズに差し替える
  const big = innerWidth / n * devicePixelRatio > 660;
  document.querySelectorAll(".tile img[data-id]").forEach((img) => {
    const want = `/api/images/${img.dataset.id}/${big ? "medium" : "thumb"}`;
    if (!img.src.endsWith(want)) img.src = want;
  });
}
$("cols").oninput = (e) => setCols(Number(e.target.value));
$("cols-minus").onclick = () => setCols(getCols() - 1);
$("cols-plus").onclick = () => setCols(getCols() + 1);
window.addEventListener("resize", applyCols);

// ---- グリッド ----

/// タイルに映る範囲(アプリの表示位置の調整と同じ計算)
function placeImage(img, w, h, x = 0.5, y = 0.5, zoom = 1) {
  if (!w || !h) { Object.assign(img.style, { width: "100%", height: "100%", left: 0, top: 0, objectFit: "cover" }); return; }
  const s = 1 / Math.min(w, h) * Math.max(1, zoom);
  const W = w * s, H = h * s;
  const left = Math.min(0, Math.max(1 - W, 0.5 - x * W));
  const top = Math.min(0, Math.max(1 - H, 0.5 - y * H));
  Object.assign(img.style, { width: W * 100 + "%", height: H * 100 + "%", left: left * 100 + "%", top: top * 100 + "%" });
}

function tileImg(imageId) {
  const img = document.createElement("img");
  img.loading = "lazy";
  img.decoding = "async";
  img.alt = "";
  if (imageId) {
    img.dataset.id = imageId;
    img.src = `/api/images/${imageId}/thumb`;
  }
  return img;
}

function render() {
  const f = state.folder;
  $("title").textContent = f ? f.name : "View Fans";
  $("back").style.visibility = f ? "visible" : "hidden";
  $("upload-btn").hidden = !f;
  $("select-btn").hidden = !state.items.length;
  const grid = $("grid");
  grid.replaceChildren();
  for (const sub of state.folders) {
    const t = document.createElement("div");
    t.className = "tile folder";
    const img = tileImg(sub.cover_image_id);
    if (sub.cover_image_id) img.onload = () => placeImage(img, img.naturalWidth, img.naturalHeight,
                                                         sub.cover_crop_x, sub.cover_crop_y, sub.cover_crop_zoom);
    placeImage(img, 0, 0);
    const label = document.createElement("div");
    label.className = "label";
    label.innerHTML = `<b></b><span></span>`;
    label.querySelector("b").textContent = sub.name;
    label.querySelector("span").textContent = (sub.child_count ? `📁 ${sub.child_count}  ` : "") + `🖼 ${sub.item_count}`;
    t.append(img, label);
    t.onclick = () => { if (!state.selecting) location.hash = `#/f/${sub.id}`; };
    grid.append(t);
  }
  state.items.forEach((it, i) => {
    const t = document.createElement("div");
    t.className = "tile image";
    t.dataset.item = it.id;
    const img = tileImg(it.image_id);
    placeImage(img, it.width, it.height, it.crop_x, it.crop_y, it.crop_zoom);
    const check = document.createElement("div");
    check.className = "check";
    t.append(img, check);
    t.onclick = () => state.selecting ? toggle(it.id, t) : openViewer(i);
    grid.append(t);
  });
  $("empty").hidden = state.folders.length + state.items.length > 0;
  applyCols();
}

$("back").onclick = () => {
  const p = state.folder && state.folder.parent_id;
  location.hash = p ? `#/f/${p}` : "#/";
};

// ---- 選択とダウンロード ----

function setSelecting(on) {
  state.selecting = on;
  state.selected.clear();
  document.body.classList.toggle("selecting", on);
  $("selectbar").hidden = !on;
  document.querySelectorAll(".tile.selected").forEach((t) => t.classList.remove("selected"));
  updateSelCount();
}
function toggle(id, tile) {
  if (state.selected.has(id)) state.selected.delete(id); else state.selected.add(id);
  tile.classList.toggle("selected", state.selected.has(id));
  updateSelCount();
}
function updateSelCount() {
  $("sel-count").textContent = `${state.selected.size} 枚を選択`;
  $("sel-download").disabled = state.selected.size === 0;
}
$("select-btn").onclick = () => setSelecting(!state.selecting);
$("sel-done").onclick = () => setSelecting(false);
$("sel-all").onclick = () => {
  const all = state.selected.size === state.items.length;
  state.selected = new Set(all ? [] : state.items.map((it) => it.id));
  document.querySelectorAll(".tile.image").forEach((t) =>
    t.classList.toggle("selected", state.selected.has(Number(t.dataset.item))));
  updateSelCount();
};
$("sel-download").onclick = () => {
  const ids = state.items.filter((it) => state.selected.has(it.id)).map((it) => it.id);
  if (ids.length === 1) { location.href = `/api/items/${ids[0]}/download`; return; }
  const form = $("zip-form");
  form.elements.namedItem("ids").value = ids.join(",");
  form.elements.namedItem("name").value = state.folder ? state.folder.name : "viewfans";
  form.submit();
};

// ---- アップロード(1枚ずつ順番に送る) ----

$("upload-btn").onclick = () => $("file").click();
$("file").onchange = (e) => { upload([...e.target.files]); e.target.value = ""; };

let dragDepth = 0;
window.addEventListener("dragenter", (e) => {
  if (!state.folder || !e.dataTransfer.types.includes("Files")) return;
  dragDepth++;
  $("drop").hidden = false;
});
window.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; $("drop").hidden = true; } });
window.addEventListener("dragover", (e) => { if (state.folder) e.preventDefault(); });
window.addEventListener("drop", (e) => {
  e.preventDefault();
  dragDepth = 0;
  $("drop").hidden = true;
  if (state.folder) upload([...e.dataTransfer.files].filter((f) => f.type.startsWith("image/") || /\.(heic|heif|webp)$/i.test(f.name)));
});

async function upload(files) {
  if (!files.length || !state.folder) return;
  const fid = state.folder.id;
  let added = 0, dup = 0;
  const failed = [];
  $("progress").hidden = false;
  for (let i = 0; i < files.length; i++) {
    $("progress-text").textContent = `アップロード中 ${i} / ${files.length}`;
    $("progress-bar").style.width = `${i / files.length * 100}%`;
    const body = new FormData();
    body.append("file", files[i], files[i].name);
    try {
      const r = await api(`/api/folders/${fid}/items`, { method: "POST", body });
      if (r.duplicate) dup++; else added++;
    } catch (err) {
      failed.push(`${files[i].name}: ${err.message}`);
    }
  }
  $("progress-bar").style.width = "100%";
  $("progress-text").textContent = `保存 ${added} 枚` + (dup ? `、保存済み ${dup} 枚` : "") + (failed.length ? `、失敗 ${failed.length} 枚` : "");
  if (failed.length) alert("失敗した画像:\n" + failed.join("\n"));
  setTimeout(() => { $("progress").hidden = true; }, 4000);
  if (state.folder && state.folder.id === fid) route();
}

// ---- 拡大表示 ----

function openViewer(i) {
  state.viewer = i;
  $("viewer").hidden = false;
  showViewer();
}
function showViewer() {
  const it = state.items[state.viewer];
  if (!it) return;
  const img = $("viewer-img");
  img.src = `/api/images/${it.image_id}/medium`;
  const original = new Image();
  original.onload = () => { if (state.items[state.viewer] === it) img.src = original.src; };
  original.src = `/api/images/${it.image_id}/original`;
  $("v-count").textContent = `${state.viewer + 1} / ${state.items.length}`;
  $("v-download").href = `/api/items/${it.id}/download`;
  $("v-prev").disabled = state.viewer === 0;
  $("v-next").disabled = state.viewer === state.items.length - 1;
}
function step(d) {
  const n = state.viewer + d;
  if (n < 0 || n >= state.items.length) return;
  state.viewer = n;
  showViewer();
}
function closeViewer() {
  state.viewer = -1;
  $("viewer").hidden = true;
  $("viewer-img").removeAttribute("src");
}
$("v-close").onclick = closeViewer;
$("v-prev").onclick = () => step(-1);
$("v-next").onclick = () => step(1);
document.addEventListener("keydown", (e) => {
  if ($("viewer").hidden) return;
  if (e.key === "Escape") closeViewer();
  if (e.key === "ArrowLeft") step(-1);
  if (e.key === "ArrowRight") step(1);
});
// スマホ: 左右のスワイプで前後、下スワイプで閉じる(拡大中は無視)
let touch = null;
$("viewer").addEventListener("touchstart", (e) => {
  touch = e.touches.length === 1 && (!visualViewport || visualViewport.scale <= 1.01)
    ? { x: e.touches[0].clientX, y: e.touches[0].clientY } : null;
}, { passive: true });
$("viewer").addEventListener("touchend", (e) => {
  if (!touch) return;
  const dx = e.changedTouches[0].clientX - touch.x, dy = e.changedTouches[0].clientY - touch.y;
  touch = null;
  if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) step(dx < 0 ? 1 : -1);
  else if (dy > 80 && dy > Math.abs(dx)) closeViewer();
});

route();
