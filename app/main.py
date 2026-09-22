#!/usr/bin/env python3
"""The pod's own little web app: a file API, so code on the volume can be replaced without an image rebuild.

  PUT /pod/app/api/files?path=<rel>   write a file under this app (scripts/push.sh: this app + ImageLab's dist/)
  PUT /pod/app/api/node?path=<rel>    write a file under ImageLabCore (scripts/push-node.sh)

It is deliberately stdlib-only. Anything pip-installed would live in the image, and the whole point of this
directory is that it changes without one. nginx already puts basic auth in front of every route, so there is no
auth here; keep it that way by never exposing this port publicly.
"""
import json, os, shutil, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP = Path(__file__).resolve().parent
# ImageLabCore, on the volume and symlinked into ComfyUI's custom_nodes. Custom nodes normally live
# in the image, which makes every one-line change a ten minute rebuild and a pod resume. Kept here
# instead, it can be written to while the pod runs; ComfyUI then re-execs in place to pick it up.
NODE = Path(os.environ.get("IMAGELAB_NODE_DIR", "/workspace/ImageLabCore"))
PORT = int(os.environ.get("IMAGELAB_APP_PORT", "8190"))


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a) -> None:      # nginx already logs; this would only double it
        pass

    def do_GET(self) -> None:
        return self._json(404, {"error": "not found"})

    def do_PUT(self) -> None:
        u = urllib.parse.urlparse(self.path)
        p = u.path[len("/pod/app"):] if u.path.startswith("/pod/app") else u.path
        rel = urllib.parse.parse_qs(u.query).get("path", [""])[0]
        # Read the body before any early answer: left unread, it is parsed as the next request on this connection.
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        root = {"/api/files": APP, "/api/node": NODE}.get(p)
        if root is None:
            return self._json(404, {"error": "not found"})
        if not rel:
            return self._json(400, {"error": "path required"})
        f = (root / rel).resolve()
        # resolve() first, then compare: a `..` or a symlink that climbs out must not be written.
        if not str(f).startswith(str(root.resolve()) + os.sep):
            return self._json(400, {"error": "outside the target directory"})
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(body)
        if root is NODE:
            # A stale .pyc next to a rewritten .py is a genuinely confusing way to lose an hour.
            for cache in NODE.rglob("__pycache__"):
                shutil.rmtree(cache, ignore_errors=True)
        return self._json(200, {"wrote": rel, "bytes": f.stat().st_size})


if __name__ == "__main__":
    print(f"[app] listening on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
