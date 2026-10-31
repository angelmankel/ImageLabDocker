#!/usr/bin/env bash
# Local test of download-models.sh's status file (DOWNLOAD_STATUS, read by gpu-agent 0.1.5 for ImageLab's Download
# queue), its aria2 completion hook and aria2's RPC for the agent's progress (DOWNLOAD_RPC_FILE, gpu-agent 0.1.6).
# No network, no docker, no real models folder: a throwaway folder, a python http.server on 127.0.0.1 serving a few
# tiny files, and a fake aria2c (curl + the --on-download-complete hook, run asynchronously like aria2's; with
# enable-rpc in its --conf-path it then stays up, like aria2, answering the RPC until aria2.shutdown). The real
# aria2c is covered by scripts/container-test.sh in CI.
#
#   scripts/download-status-test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
srv_pid=
cleanup() { [ -z "$srv_pid" ] || kill "$srv_pid" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
fails=0
check() { local what=$1; shift; if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails+1)); fi; }

# ---- the files the "internet" serves --------------------------------------------------------------------------
mkdir -p "$T/www" "$T/bin" "$T/models"
printf 'placeholder model a\n' > "$T/www/a.bin"
printf 'placeholder model b, longer than a\n' > "$T/www/b.bin"
head -c 300000 /dev/urandom > "$T/www/e.bin"                      # big enough to be cut in half
for f in f1 f2 f3; do printf 'placeholder %s\n' "$f" > "$T/www/$f.bin"; done
printf '<html><body>Our CDN is down</body></html>\n' > "$T/www/g.html"
size() { stat -c %s "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
# The "internet": files from www/ with ranges, plus what went wrong on the pod (#261031): /api/download/models/<id> is
# CivitAI without a key (302 to a ~9.8 KB login page, 200 text/html); /drop/<f> sends half of a file and hangs up unless
# asked for a range; /curlonly/<f> refuses the fake aria2 (503) and answers curl slowly, counting how many run at once.
cat > "$T/bin/www.py" <<'WWW'
import http.server, os, sys, threading, time
root, port, log = sys.argv[1], int(sys.argv[2]), open(sys.argv[3], "a")
lock = threading.Lock(); now = {"n": 0, "max": 0}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path.split("?")[0]
        log.write(f"GET {p} range={self.headers.get('Range', '-')}\n"); log.flush()
        if p.startswith("/api/download/models/"):
            self.send_response(302); self.send_header("Location", "/login?returnUrl=%2Fmodel-versions%2F" + p.rsplit("/", 1)[1] + "&reason=download-auth"); self.end_headers(); return
        if p == "/login":
            body = b"<!DOCTYPE html><html><body>Sign in" + b" " * 9750 + b"</body></html>"
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        mode, name = (p.split("/")[1], p.split("/")[2]) if p.count("/") == 2 else ("plain", p.lstrip("/"))
        if mode == "curlonly" and self.headers.get("X-Fake-Aria2"):
            self.send_error(503); return
        f = os.path.join(root, name)
        if not os.path.isfile(f): self.send_error(404); return
        data = open(f, "rb").read(); a = 0
        r = self.headers.get("Range")
        if r: a = int(r.split("=")[1].split("-")[0]); self.send_response(206); self.send_header("Content-Range", f"bytes {a}-{len(data)-1}/{len(data)}")
        else: self.send_response(200)
        self.send_header("Content-Type", "text/html" if name.endswith(".html") else "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(len(data) - a)); self.end_headers()
        if mode == "drop" and not r:
            self.wfile.write(data[: len(data) // 2]); self.wfile.flush(); self.connection.shutdown(2); return
        if mode == "curlonly":
            with lock: now["n"] += 1; now["max"] = max(now["max"], now["n"]); log.write(f"curlonly max {now['max']}\n"); log.flush()
            time.sleep(0.8)
            with lock: now["n"] -= 1
        self.wfile.write(data[a:])
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
WWW
python3 "$T/bin/www.py" "$T/www" "$port" "$T/www.log" >/dev/null 2>&1 &
srv_pid=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null "http://127.0.0.1:$port/a.bin" && break; sleep 0.1; done
U="http://127.0.0.1:$port"

# ---- a fake aria2c: input file entries (url, then "  dir=", "  out="), curl each, then the hook like aria2 ----------
cat > "$T/bin/aria2c" <<'FAKE'
#!/usr/bin/env bash
input= hook= rc=0 conf= results=
for a in "$@"; do case "$a" in --input-file=*) input=${a#*=} ;; --on-download-complete=*) hook=${a#*=} ;; --conf-path=*) conf=${a#*=} ;; esac; done
url= dir= out=
fetch() {
  [ -n "$url" ] || return 0
  mkdir -p "$dir"; : > "$dir/$out.aria2"
  if curl -fsSL -H "X-Fake-Aria2: 1" -o "$dir/$out" "$url" 2>/dev/null; then
    rm -f "$dir/$out.aria2"; results+=complete,
    [ -z "$hook" ] || "$hook" "gid$RANDOM" 1 "$dir/$out" &   # aria2 does not wait for its hooks
  else rm -f "$dir/$out" "$dir/$out.aria2"; rc=1; results+=error,; fi
  url= dir= out=
}
while IFS= read -r line; do
  case "$line" in
    "  dir="*) dir=${line#  dir=} ;;
    "  out="*) out=${line#  out=} ;;
    "  "*) ;;
    *) fetch; url=$line ;;
  esac
done < "$input"
fetch
sleep 1                                              # the hooks run while aria2 is still busy
cp "$DOWNLOAD_STATUS" "$FAKE_SNAPSHOT" 2>/dev/null || true
if [ -n "$conf" ] && grep -qx 'enable-rpc=true' "$conf"; then
  # aria2 with RPC does not exit after its input file: answer until aria2.shutdown (the script must send it)
  [ -n "${FAKE_RPC_SEEN:-}" ] && { cat "$DOWNLOAD_RPC_FILE"; stat -c 'mode %a' "$DOWNLOAD_RPC_FILE"; } > "$FAKE_RPC_SEEN" 2>&1
  exec python3 "$(dirname "$0")/fake-rpc.py" "$conf" "$results" "$FAKE_RPC_LOG"
fi
exit $rc
FAKE
chmod +x "$T/bin/aria2c"
cat > "$T/bin/fake-rpc.py" <<'RPC'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
conf = dict(l.strip().split("=", 1) for l in open(sys.argv[1]) if "=" in l)
statuses = [r for r in sys.argv[2].split(",") if r]
log = open(sys.argv[3], "a")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        ok = req["params"][0] == "token:" + conf["rpc-secret"]
        log.write(f"{req['method']} token={'ok' if ok else 'BAD'}\n"); log.flush()
        if not ok: res = {"error": {"code": 1, "message": "Unauthorized"}}
        elif req["method"] == "aria2.getGlobalStat": res = {"result": {"numActive": "0", "numWaiting": "0", "numStopped": str(len(statuses)), "numStoppedTotal": str(len(statuses))}}
        elif req["method"] == "aria2.tellStopped": res = {"result": [{"status": s} for s in statuses]}
        else: res = {"result": "OK"}
        body = json.dumps({"id": req["id"], "jsonrpc": "2.0", **res}, separators=(",", ":")).encode()  # compact, as aria2
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        if ok and req["method"] == "aria2.shutdown": threading.Thread(target=srv.shutdown).start()
srv = HTTPServer(("127.0.0.1", int(conf["rpc-listen-port"])), H)
timer = threading.Timer(30, lambda: (log.write("TIMEOUT no shutdown\n"), log.flush(), srv.shutdown()))
timer.daemon = True
timer.start()
srv.serve_forever()
timer.cancel()
sys.exit(1 if "error" in statuses else 0)
RPC

manifest="$T/manifest.tsv"
{
  printf 'url\tfolder\tname\tbytes\tsha256\n'
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/a.bin" checkpoints a.safetensors "$(size "$T/www/a.bin")" "$(sha "$T/www/a.bin")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/b.bin" loras b.safetensors "$(size "$T/www/b.bin")" "$(printf '0%.0s' $(seq 1 64))"   # wrong hash
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/missing.bin" vae c.safetensors 123 -                                                     # 404
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/a.bin" upscale_models kept.pth 999 -                                                    # already there
  printf '%s\t%s\t%s\t%s\t%s\n' civitai:4242 loras d.safetensors 53857340 -                                                   # login page
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/drop/e.bin" checkpoints e.safetensors "$(size "$T/www/e.bin")" "$(sha "$T/www/e.bin")"      # resumed
  for f in f1 f2 f3; do printf '%s\t%s\t%s\t%s\t%s\n' "$U/curlonly/$f.bin" embeddings "$f.pt" "$(size "$T/www/$f.bin")" -; done # curl only
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/g.html" vae g.safetensors 1000 -                                                          # an HTML page
} > "$manifest"
mkdir -p "$T/models/upscale_models" && echo mine > "$T/models/upscale_models/kept.pth"
status="$T/logs/startup-downloads.tsv"
rpcfile="$T/run/imagelab/aria2-rpc.json"
rpcport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
run() {
  PATH="$T/bin:$PATH" MANIFEST="$manifest" MODELS_DIR="$T/models" DOWNLOAD_STATUS="$status" DOWNLOAD_RUN="${1:-}" \
    CIVITAI_DOWNLOAD_URL="$U/api/download/models" CIVITAI_API_KEY= DOWNLOAD_CURL_PARALLEL=2 DOWNLOAD_CURL_RETRY_WAIT=0 \
    DOWNLOAD_RPC_FILE="$rpcfile" ARIA2_RPC_PORT="$rpcport" FAKE_RPC_SEEN="$T/rpc-seen.txt" FAKE_RPC_LOG="$T/rpc.log" \
    FAKE_SNAPSHOT="$T/at-aria2-exit.tsv" timeout 120 bash "$here/download-models.sh" > "$T/out.log" 2>&1
}
row() { printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$T/models/$2/$3"; }

set +e; run 777; code=$?; set -e
sed 's/^/    /' "$T/out.log"
echo "--- status file"; sed 's/^/    /' "$status"
A=$(size "$T/www/a.bin"); B=$(size "$T/www/b.bin")
check "the run fails (four files missing), as before (and ends: not the timeout)" [ "$code" = 1 ]
check "first line: run 777" [ "$(head -1 "$status")" = "$(printf 'run\t777')" ]
check "a queued" grep -qxF "$(row queued checkpoints a.safetensors "$A")" "$status"
check "b queued" grep -qxF "$(row queued loras b.safetensors "$B")" "$status"
check "c queued" grep -qxF "$(row queued vae c.safetensors 123)" "$status"
check "the file already there is no row" bash -c "! grep -qF kept.pth '$status'"
check "a done, once" [ "$(grep -cxF "$(row done checkpoints a.safetensors "$A")" "$status")" = 1 ]
check "a done by the hook, before aria2 exited" grep -qxF "$(row done checkpoints a.safetensors "$A")" "$T/at-aria2-exit.tsv"
check "a in place with its content" cmp -s "$T/www/a.bin" "$T/models/checkpoints/a.safetensors"
check "b failed: the curl copy's sha256 is wrong" grep -qxF "$(row failed loras b.safetensors "$B")	downloaded, but the sha256 did not match the manifest" "$status"
check "d failed: CivitAI's login page, no key (the pod's 9787-byte 'size mismatch')" \
  grep -qxF "$(row failed loras d.safetensors 53857340)	CivitAI wants a login and CIVITAI_API_KEY is not set on the pod" "$status"
check "d: tried once by curl (a login page will not change)" [ "$(grep -c 'GET /api/download/models/4242' "$T/www.log")" = 2 ]
check "e: the dropped connection was retried and resumed with a range" \
  bash -c "grep -qF 'curl retry  checkpoints/e.safetensors (the connection dropped (curl 18); try 2 of 3)' '$T/out.log' && grep -q 'GET /drop/e.bin range=bytes=150000-' '$T/www.log'"
check "e: done, its content intact" bash -c "grep -qxF \"\$(printf 'done\tcheckpoints\te.safetensors\t%s\t%s' $(size "$T/www/e.bin") '$T/models/checkpoints/e.safetensors')\" '$status' && cmp -s '$T/www/e.bin' '$T/models/checkpoints/e.safetensors'"
check "f1-f3 (curl only) all done, at most 2 curls at once (DOWNLOAD_CURL_PARALLEL=2)" \
  bash -c "[ \$(grep -c '^done	embeddings	f' '$status') = 3 ] && [ \"\$(grep 'curlonly max' '$T/www.log' | tail -1)\" = 'curlonly max 2' ]"
check "g failed: an HTML page is not the file" grep -qxF "$(row failed vae g.safetensors 1000)	got an HTML page (http 200), not the file" "$status"
check "b never got its name" [ ! -e "$T/models/loras/b.safetensors" ]
check "c failed: http 404" grep -qxF "$(row failed vae c.safetensors 123)	http 404" "$status"
check "the curl fallback queued b and c again (a new attempt: curl starts from zero)" \
  [ "$(grep -c "^queued	loras	b.safetensors" "$status")" = 2 -a "$(grep -c "^queued	vae	c.safetensors" "$status")" = 2 ]
check "aria2's failures were noticed over RPC (curl fallback)" grep -qF "aria2c reported failures" "$T/out.log"
echo "--- rpc"; sed 's/^/    /' "$T/rpc.log"
check "the RPC file existed while aria2 ran: loopback URL, mode 600" \
  bash -c "grep -q '^{\"url\":\"http://127.0.0.1:$rpcport/jsonrpc\",\"secret\":\"[0-9a-f]\{48\}\"}\$' '$T/rpc-seen.txt' && grep -qx 'mode 600' '$T/rpc-seen.txt'"
check "the script asked aria2 with the secret and shut it down" bash -c "grep -qx 'aria2.shutdown token=ok' '$T/rpc.log' && ! grep -q 'BAD\|TIMEOUT' '$T/rpc.log'"
check "the RPC file is gone after the run" [ ! -e "$rpcfile" ]
check "the secret is not on aria2's command line" bash -c "! grep -q 'rpc-secret' '$T/out.log'"
check "no part left" [ -z "$(find "$T/models" -name '*.part*')" ]
check "the kept file untouched" [ "$(cat "$T/models/upscale_models/kept.pth")" = mine ]

# start.sh's next attempt in the same boot: same file, same run, only the missing ones queued again
lines=$(wc -l < "$status")
set +e; run 888; set -e
check "second attempt: no new run line" [ "$(grep -c '^run' "$status")" = 1 ]
check "second attempt: the missing ones queued again, a not" bash -c "tail -n +$((lines+1)) '$status' | grep '^queued' | cut -f3 | sort -u | tr '\n' ' ' | grep -qx 'b.safetensors c.safetensors d.safetensors g.safetensors ' && ! tail -n +$((lines+1)) '$status' | grep -qF a.safetensors"

# The RPC port taken (say by a stray aria2): aria2 runs without RPC, ends by itself, nothing else changes
python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", '"$rpcport"')); s.listen(); time.sleep(60)' &
blocker=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$rpcport") 2>/dev/null && break; sleep 0.1; done
: > "$T/rpc.log"
set +e; run 999; code=$?; set -e
kill "$blocker" 2>/dev/null || true
check "port taken: said so, no RPC, the run ends as before" bash -c "grep -qF 'port $rpcport is taken' '$T/out.log' && [ '$code' = 1 ] && [ ! -s '$T/rpc.log' ] && [ ! -e '$rpcfile' ]"

# Without DOWNLOAD_STATUS nothing is written; a dry run writes nothing either
rm -rf "$T/models/loras" "$T/logs"
PATH="$T/bin:$PATH" MANIFEST="$manifest" MODELS_DIR="$T/models" FAKE_SNAPSHOT=/dev/null bash "$here/download-models.sh" > /dev/null 2>&1 || true
check "no DOWNLOAD_STATUS: no status file" [ ! -e "$status" ]
PATH="$T/bin:$PATH" MANIFEST="$manifest" MODELS_DIR="$T/models" DOWNLOAD_STATUS="$status" DOWNLOAD_DRY_RUN=1 bash "$here/download-models.sh" > /dev/null 2>&1
check "dry run: no status file" [ ! -e "$status" ]

echo
if [ "$fails" = 0 ]; then echo "== download status test passed"; else echo "== download status test: $fails check(s) FAILED"; exit 1; fi
