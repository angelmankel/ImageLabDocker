#!/usr/bin/env python3
"""The pod's own little web app: a model installer, and a file API so this app can rewrite itself.

It is deliberately stdlib-only. Anything pip-installed would live in the image, and the whole point of this
directory is that it changes without one. nginx already puts basic auth in front of every route, so there is no
auth here; keep it that way by never exposing this port publicly.
"""
import json, mimetypes, os, re, shutil, subprocess, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP = Path(__file__).resolve().parent
MODELS = Path(os.environ.get("MODELS_DIR", "/workspace/ComfyUI/models"))
EXTRA = Path(os.environ.get("IMAGELAB_EXTRA_MANIFEST", "/workspace/models-extra.txt"))  # on the volume: survives a restart
COMFY = f"http://127.0.0.1:{os.environ.get('COMFY_PORT', '8189')}"
# ImageLabCore, on the volume and symlinked into ComfyUI's custom_nodes. Custom nodes normally live
# in the image, which makes every one-line change a ten minute rebuild and a pod resume. Kept here
# instead, it can be written to while the pod runs; ComfyUI then re-execs in place to pick it up.
NODE = Path(os.environ.get("IMAGELAB_NODE_DIR", "/workspace/ImageLabCore"))
PORT = int(os.environ.get("IMAGELAB_APP_PORT", "8190"))
CIVITAI = os.environ.get("CIVITAI_API_KEY", "")

JOBS: dict[str, dict] = {}          # install id -> {state, log[], pct}
FOLDERS = ["checkpoints", "loras", "vae", "controlnet", "upscale_models", "embeddings", "clip_vision", "ipadapter"]


def civitai_version(vid: str) -> dict:
    # Civitai answers 403 to an anonymous or user-agent-less request, and 403 to HEAD on the file itself.
    # Both are normal; neither means the key is wrong.
    headers = {"User-Agent": "imagelab"}
    if CIVITAI:
        headers["Authorization"] = f"Bearer {CIVITAI}"
    req = urllib.request.Request(f"https://civitai.com/api/v1/model-versions/{vid}", headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        v = json.load(r)
    f = next((x for x in v.get("files", []) if x.get("primary")), (v.get("files") or [None])[0]) or {}
    return {"version_id": vid, "model": v.get("model", {}).get("name", ""), "version": v.get("name", ""),
            "filename": f.get("name", ""), "size": int(float(f.get("sizeKB", 0)) * 1024),
            "base": v.get("baseModel", ""), "download": f.get("downloadUrl", "")}


def resolve(src: str) -> dict:
    """A civitai link, a bare version id, or any direct URL — all end up as one manifest row."""
    src = src.strip()
    m = re.search(r"modelVersionId=(\d+)", src) or re.search(r"model-versions/(\d+)", src)
    if m or src.isdigit():
        return civitai_version(m.group(1) if m else src)
    name = urllib.parse.unquote(src.rsplit("/", 1)[-1].split("?")[0])
    return {"version_id": "", "model": name, "version": "", "filename": name, "size": 0, "download": src}


def _aria(job: str, url: str, dest: Path, filename: str) -> bool:
    """aria2 when it is there: eight connections beats one every time."""
    j = JOBS[job]
    cmd = ["aria2c", url, "--dir", str(dest), "--out", filename, "--continue=true", "--allow-overwrite=true",
           "--auto-file-renaming=false", "--max-connection-per-server=8", "--split=8", "--min-split-size=8M",
           "--file-allocation=none", "--summary-interval=2", "--console-log-level=warn", "--show-console-readout=true",
           "--user-agent=Mozilla/5.0 (imagelab)"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    for line in p.stdout:                                   # type: ignore[union-attr]
        line = line.strip()
        if not line:
            continue
        j["log"] = (j["log"] + [line])[-40:]
        m = re.search(r"\((\d+)%\)", line)
        if m:
            j["pct"] = int(m.group(1))
    return p.wait() == 0


def _stream(job: str, url: str, dest: Path, filename: str) -> bool:
    """No aria2 (a laptop, a stripped image): one plain connection, so a missing tool is slow, never fatal."""
    j = JOBS[job]
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (imagelab)"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest / filename, "wb") as out:
        total = int(r.headers.get("Content-Length") or 0)
        got = 0
        while chunk := r.read(1 << 20):
            out.write(chunk)
            got += len(chunk)
            if total:
                j["pct"] = int(got * 100 / total)
    j["log"] = (j["log"] + [f"streamed {got} bytes"])[-40:]
    return True


def run_install(job: str, url: str, folder: str, filename: str, size: int, note: str) -> None:
    j = JOBS[job]
    try:
        dest = MODELS / folder
        dest.mkdir(parents=True, exist_ok=True)
        if url.startswith("https://civitai.com") and CIVITAI and "token=" not in url:
            url = f"{url}{'&' if '?' in url else '?'}token={CIVITAI}"
        j["state"] = "downloading"
        try:
            ok = _aria(job, url, dest, filename)
        except FileNotFoundError:
            j["log"] = j["log"] + ["aria2c not installed; falling back to a single connection"]
            ok = _stream(job, url, dest, filename)
        path = dest / filename
        if not (ok and path.exists() and path.stat().st_size > 0):
            j.update(state="error", log=j["log"] + ["download did not produce a file"])
            return
        real = path.stat().st_size
        row = f"{('civitai:' + j['version_id']) if j.get('version_id') else url.split('?')[0]}\t{folder}\t{filename}\t{real}"
        # The model is on disk and usable from here on. Recording it is bookkeeping, so a failure to write the
        # manifest is a warning on a finished job, never a failed install.
        try:
            prev = EXTRA.read_text() if EXTRA.exists() else "# added from /pod/app - mirror these into ImageLabDocker/models.txt\n"
            if row not in prev:
                EXTRA.parent.mkdir(parents=True, exist_ok=True)
                EXTRA.write_text(prev + row + "\n")
        except OSError as e:
            j["log"] = j["log"] + [f"installed, but could not write {EXTRA}: {e}"]
        j.update(state="done", pct=100, manifest=row, bytes=real)
        try:
            urllib.request.urlopen(f"{COMFY}/object_info", timeout=30)   # nudge comfy to re-read its folders
        except Exception:
            pass
    except Exception as e:
        # A thread that dies quietly leaves the page spinning at 0% for ever, which is the worst way to fail.
        j.update(state="error", log=(j.get("log") or []) + [f"{type(e).__name__}: {e}"])


# Civitai, proxied. The key lives here and never reaches the browser, the browser never fights CORS, and one
# short-lived cache keeps a filter click from hammering the API.
CIV_BASE = "https://civitai.com/api/v1"
CACHE: dict[str, tuple[float, dict]] = {}
CACHE_TTL = 120

# What a model type means for where its file belongs on disk.
FOLDER_OF = {"Checkpoint": "checkpoints", "LORA": "loras", "LoCon": "loras", "DoRA": "loras",
             "TextualInversion": "embeddings", "VAE": "vae", "Controlnet": "controlnet",
             "Upscaler": "upscale_models", "MotionModule": "checkpoints", "Hypernetwork": "checkpoints"}
TYPES = list(FOLDER_OF) + ["Poses", "Wildcards", "Workflows", "Other"]
BASES = ["Illustrious", "NoobAI", "Pony", "SDXL 1.0", "SDXL Turbo", "SD 1.5", "SD 3.5", "Flux.1 D", "Flux.1 S",
         "Anima", "Qwen", "Wan Video", "Hunyuan Video", "Other"]
SORTS = ["Highest Rated", "Most Downloaded", "Most Liked", "Newest"]


def civitai_get(path: str, params: dict) -> dict:
    qs = urllib.parse.urlencode([(k, v) for k, vs in params.items() for v in (vs if isinstance(vs, list) else [vs]) if v not in ("", None)])
    url = f"{CIV_BASE}/{path}?{qs}"
    hit = CACHE.get(url)
    if hit and time.time() - hit[0] < CACHE_TTL:
        return hit[1]
    headers = {"User-Agent": "imagelab"}
    if CIVITAI:
        headers["Authorization"] = f"Bearer {CIVITAI}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=45) as r:
        data = json.load(r)
    CACHE[url] = (time.time(), data)
    if len(CACHE) > 200:
        for k in sorted(CACHE, key=lambda k: CACHE[k][0])[:100]:
            CACHE.pop(k, None)
    return data


def on_disk() -> set[str]:
    out: set[str] = set()
    for folder in FOLDERS:
        d = MODELS / folder
        if d.is_dir():
            out |= {f.name for f in d.iterdir() if f.is_file()}
    return out


def slim(m: dict, have: set[str]) -> dict:
    """One card's worth of a Civitai model: what to show, what to install, and whether we already have it."""
    versions = []
    for v in m.get("modelVersions", [])[:12]:
        files = [{"name": f.get("name"), "bytes": int(float(f.get("sizeKB", 0)) * 1024),
                  "primary": bool(f.get("primary")), "format": (f.get("metadata") or {}).get("format")}
                 for f in v.get("files", []) if f.get("type") == "Model"]
        images = [i.get("url") for i in v.get("images", []) if i.get("type", "image") == "image"][:4]
        versions.append({"id": v.get("id"), "name": v.get("name"), "base": v.get("baseModel"),
                         "published": (v.get("publishedAt") or "")[:10], "words": v.get("trainedWords") or [],
                         "files": files, "images": images,
                         "installed": any(f["name"] in have for f in files)})
    cover = next((i for v in versions for i in v["images"]), None)
    stats = m.get("stats", {})
    return {"id": m.get("id"), "name": m.get("name"), "type": m.get("type"), "nsfw": m.get("nsfw"), "cover": cover,
            "creator": (m.get("creator") or {}).get("username", ""),
            "downloads": stats.get("downloadCount", 0), "thumbsUp": stats.get("thumbsUpCount", 0),
            "tags": (m.get("tags") or [])[:6], "folder": FOLDER_OF.get(m.get("type", ""), "checkpoints"),
            "versions": versions, "installed": any(v["installed"] for v in versions)}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json")

    def log_message(self, *a) -> None:      # nginx already logs; this would only double it
        pass

    # ---- GET ---------------------------------------------------------------
    def do_GET(self) -> None:
        u = urllib.parse.urlparse(self.path)
        p = u.path[len("/pod/app"):] if u.path.startswith("/pod/app") else u.path
        q = urllib.parse.parse_qs(u.query)
        if p in ("", "/"):
            return self._send(200, (APP / "index.html").read_bytes(), "text/html; charset=utf-8")
        if p == "/lab" or p.startswith("/lab/"):
            # Serving the SPA here as well as through nginx. nginx had no mime.types and handed the browser a
            # module as text/plain, which it refuses; python guesses the type properly, and this path can be
            # fixed on a running pod, where the nginx config cannot.
            rel = p[len("/lab/"):] if p.startswith("/lab/") else ""
            f = (APP / "lab" / rel).resolve()
            if not str(f).startswith(str(APP / "lab")):
                return self._json(400, {"error": "outside the app"})
            if f.is_dir() or not rel:
                f = APP / "lab" / "index.html"
            if not f.is_file():
                f = APP / "lab" / "index.html"          # deep links still land on the app
            ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
                ctype += "; charset=utf-8"
            return self._send(200, f.read_bytes(), ctype)
        if p == "/api/state":
            return self._json(200, {"folders": FOLDERS, "models": self.inventory(), "jobs": JOBS,
                                    "extra": EXTRA.read_text().splitlines() if EXTRA.exists() else []})
        if p == "/api/civitai/meta":
            return self._json(200, {"types": TYPES, "bases": BASES, "sorts": SORTS, "key": bool(CIVITAI)})
        if p == "/api/civitai/search":
            try:
                data = civitai_get("models", {
                    "limit": q.get("limit", ["24"])[0], "cursor": q.get("cursor", [""])[0],
                    "query": q.get("query", [""])[0], "types": q.get("types", []),
                    "baseModels": q.get("bases", []), "sort": q.get("sort", ["Most Downloaded"])[0],
                    "nsfw": q.get("nsfw", ["false"])[0], "period": q.get("period", ["AllTime"])[0]})
                have = on_disk()
                meta = data.get("metadata", {})
                return self._json(200, {"items": [slim(m, have) for m in data.get("items", [])],
                                        "cursor": meta.get("nextCursor"), "total": meta.get("totalItems", 0)})
            except Exception as e:
                return self._json(502, {"error": f"{type(e).__name__}: {e}"})
        if p == "/api/civitai/image":
            # Some Civitai CDN images dislike a cross-site referrer; going through the pod sidesteps it.
            src = q.get("url", [""])[0]
            if not src.startswith("https://image.civitai.com/"):
                return self._json(400, {"error": "not a civitai image"})
            # Civitai resizes on its CDN through a /width=N/ path segment. A card is 230px wide; fetching the
            # 1.5 MB original for each of 24 of them is a slideshow, so ask for the size actually drawn.
            # The transform is its own path segment: .../<uuid>/original=true/<n>.jpeg or .../<uuid>/width=N/<n>.jpeg.
            # Replacing that segment is what shrinks the file; inserting a new one is ignored and you still get 1.5 MB.
            w = q.get("w", ["450"])[0]
            src = re.sub(r"/(original=true|width=\d+|height=\d+)(,[^/]*)?/", f"/width={w}/", src, count=1)
            try:
                with urllib.request.urlopen(urllib.request.Request(src, headers={"User-Agent": "imagelab"}), timeout=30) as r:
                    return self._send(200, r.read(), r.headers.get("Content-Type", "image/jpeg"))
            except Exception as e:
                return self._json(502, {"error": str(e)})
        if p == "/api/resolve":
            try:
                return self._json(200, resolve(q.get("src", [""])[0]))
            except Exception as e:
                hint = " (no CIVITAI_API_KEY in the pod env?)" if "403" in str(e) and not CIVITAI else ""
                return self._json(400, {"error": f"{e}{hint}"})
        if p == "/api/files":                      # the file API: this app can be edited through itself
            rel = q.get("path", [""])[0]
            if rel:
                f = (APP / rel).resolve()
                if not str(f).startswith(str(APP)) or not f.is_file():
                    return self._json(404, {"error": "no such file"})
                return self._send(200, f.read_bytes(), "text/plain; charset=utf-8")
            return self._json(200, {"files": sorted(str(f.relative_to(APP)) for f in APP.rglob("*")
                                                    if f.is_file() and "__pycache__" not in str(f))})
        if p == "/api/node":                       # the same idea, pointed at the custom node
            rel = q.get("path", [""])[0]
            if rel:
                f = (NODE / rel).resolve()
                if not str(f).startswith(str(NODE.resolve())) or not f.is_file():
                    return self._json(404, {"error": "no such file"})
                return self._send(200, f.read_bytes(), "text/plain; charset=utf-8")
            if not NODE.is_dir():
                return self._json(404, {"error": f"{NODE} does not exist — is the pod on an image that seeds it?"})
            return self._json(200, {"files": sorted(str(f.relative_to(NODE)) for f in NODE.rglob("*")
                                                    if f.is_file() and "__pycache__" not in str(f))})
        return self._json(404, {"error": "not found"})

    # ---- POST / PUT --------------------------------------------------------
    def do_POST(self) -> None:
        u = urllib.parse.urlparse(self.path)
        p = u.path[len("/pod/app"):] if u.path.startswith("/pod/app") else u.path
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        data = json.loads(body or b"{}")
        if p == "/api/install":
            info = resolve(data.get("src", ""))
            folder = data.get("folder") or "checkpoints"
            filename = data.get("filename") or info["filename"]
            if not filename:
                return self._json(400, {"error": "could not work out a filename"})
            job = str(int(time.time() * 1000))
            JOBS[job] = {"id": job, "state": "starting", "pct": 0, "log": [], "folder": folder,
                         "filename": filename, "version_id": info.get("version_id", ""), "name": info.get("model", "")}
            threading.Thread(target=run_install, daemon=True,
                             args=(job, info["download"] or data.get("src", ""), folder, filename,
                                   info.get("size", 0), data.get("note", ""))).start()
            return self._json(200, {"job": job})
        return self._json(404, {"error": "not found"})

    def do_PUT(self) -> None:
        u = urllib.parse.urlparse(self.path)
        p = u.path[len("/pod/app"):] if u.path.startswith("/pod/app") else u.path
        q = urllib.parse.parse_qs(u.query)
        if p == "/api/files":
            rel = q.get("path", [""])[0]
            if not rel:
                return self._json(400, {"error": "path required"})
            f = (APP / rel).resolve()
            if not str(f).startswith(str(APP)):
                return self._json(400, {"error": "outside the app directory"})
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)))
            return self._json(200, {"wrote": rel, "bytes": f.stat().st_size})
        if p == "/api/node":
            rel = q.get("path", [""])[0]
            if not rel:
                return self._json(400, {"error": "path required"})
            f = (NODE / rel).resolve()
            # resolve() first, then compare: a `..` or a symlink that climbs out must not be written.
            if not str(f).startswith(str(NODE.resolve())):
                return self._json(400, {"error": "outside the node directory"})
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)))
            # A stale .pyc next to a rewritten .py is a genuinely confusing way to lose an hour.
            for cache in NODE.rglob("__pycache__"):
                shutil.rmtree(cache, ignore_errors=True)
            return self._json(200, {"wrote": rel, "bytes": f.stat().st_size})
        return self._json(404, {"error": "not found"})

    def inventory(self) -> dict:
        out: dict[str, list] = {}
        for folder in FOLDERS:
            d = MODELS / folder
            if not d.is_dir():
                continue
            out[folder] = sorted(({"name": f.name, "bytes": f.stat().st_size}
                                  for f in d.iterdir() if f.is_file() and not f.name.endswith(".aria2")),
                                 key=lambda x: x["name"])
        return out


if __name__ == "__main__":
    print(f"[app] listening on 127.0.0.1:{PORT}, models at {MODELS}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
