#!/usr/bin/env bash
# Local test of download-models.sh's status file (DOWNLOAD_STATUS, read by gpu-agent 0.1.5 for ImageLab's Download
# queue) and its aria2 completion hook. No network, no docker, no real models folder: a throwaway folder, a python
# http.server on 127.0.0.1 serving a few tiny files, and a fake aria2c (curl + the --on-download-complete hook, run
# asynchronously like aria2's). The real aria2c is covered by scripts/container-test.sh in CI.
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
size() { stat -c %s "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
(cd "$T/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
srv_pid=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null "http://127.0.0.1:$port/a.bin" && break; sleep 0.1; done
U="http://127.0.0.1:$port"

# ---- a fake aria2c: input file entries (url, then "  dir=", "  out="), curl each, then the hook like aria2 ----------
cat > "$T/bin/aria2c" <<'FAKE'
#!/usr/bin/env bash
input= hook= rc=0
for a in "$@"; do case "$a" in --input-file=*) input=${a#*=} ;; --on-download-complete=*) hook=${a#*=} ;; esac; done
url= dir= out=
fetch() {
  [ -n "$url" ] || return 0
  mkdir -p "$dir"; : > "$dir/$out.aria2"
  if curl -fsS -o "$dir/$out" "$url" 2>/dev/null; then
    rm -f "$dir/$out.aria2"
    [ -z "$hook" ] || "$hook" "gid$RANDOM" 1 "$dir/$out" &   # aria2 does not wait for its hooks
  else rm -f "$dir/$out" "$dir/$out.aria2"; rc=1; fi
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
exit $rc
FAKE
chmod +x "$T/bin/aria2c"

manifest="$T/manifest.tsv"
{
  printf 'url\tfolder\tname\tbytes\tsha256\n'
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/a.bin" checkpoints a.safetensors "$(size "$T/www/a.bin")" "$(sha "$T/www/a.bin")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/b.bin" loras b.safetensors "$(size "$T/www/b.bin")" "$(printf '0%.0s' $(seq 1 64))"   # wrong hash
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/missing.bin" vae c.safetensors 123 -                                                     # 404
  printf '%s\t%s\t%s\t%s\t%s\n' "$U/a.bin" upscale_models kept.pth 999 -                                                    # already there
} > "$manifest"
mkdir -p "$T/models/upscale_models" && echo mine > "$T/models/upscale_models/kept.pth"
status="$T/logs/startup-downloads.tsv"
run() {
  PATH="$T/bin:$PATH" MANIFEST="$manifest" MODELS_DIR="$T/models" DOWNLOAD_STATUS="$status" DOWNLOAD_RUN="${1:-}" \
    FAKE_SNAPSHOT="$T/at-aria2-exit.tsv" bash "$here/download-models.sh" > "$T/out.log" 2>&1
}
row() { printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$T/models/$2/$3"; }

set +e; run 777; code=$?; set -e
sed 's/^/    /' "$T/out.log"
echo "--- status file"; sed 's/^/    /' "$status"
A=$(size "$T/www/a.bin"); B=$(size "$T/www/b.bin")
check "the run fails (two files missing), as before" [ "$code" = 1 ]
check "first line: run 777" [ "$(head -1 "$status")" = "$(printf 'run\t777')" ]
check "a queued" grep -qxF "$(row queued checkpoints a.safetensors "$A")" "$status"
check "b queued" grep -qxF "$(row queued loras b.safetensors "$B")" "$status"
check "c queued" grep -qxF "$(row queued vae c.safetensors 123)" "$status"
check "the file already there is no row" bash -c "! grep -qF kept.pth '$status'"
check "a done, once" [ "$(grep -cxF "$(row done checkpoints a.safetensors "$A")" "$status")" = 1 ]
check "a done by the hook, before aria2 exited" grep -qxF "$(row done checkpoints a.safetensors "$A")" "$T/at-aria2-exit.tsv"
check "a in place with its content" cmp -s "$T/www/a.bin" "$T/models/checkpoints/a.safetensors"
check "b failed: the curl copy did not check out" grep -qxF "$(row failed loras b.safetensors "$B")	downloaded, but the size or sha256 did not match" "$status"
check "b never got its name" [ ! -e "$T/models/loras/b.safetensors" ]
check "c failed: http 404" grep -qxF "$(row failed vae c.safetensors 123)	http 404" "$status"
check "no part left" [ -z "$(find "$T/models" -name '*.part*')" ]
check "the kept file untouched" [ "$(cat "$T/models/upscale_models/kept.pth")" = mine ]

# start.sh's next attempt in the same boot: same file, same run, only the missing ones queued again
lines=$(wc -l < "$status")
set +e; run 888; set -e
check "second attempt: no new run line" [ "$(grep -c '^run' "$status")" = 1 ]
check "second attempt: b and c queued again, a not" bash -c "tail -n +$((lines+1)) '$status' | cut -f1,3 | grep -c '^queued' | grep -qx 2 && ! tail -n +$((lines+1)) '$status' | grep -qF a.safetensors"

# Without DOWNLOAD_STATUS nothing is written; a dry run writes nothing either
rm -rf "$T/models/loras" "$T/logs"
PATH="$T/bin:$PATH" MANIFEST="$manifest" MODELS_DIR="$T/models" FAKE_SNAPSHOT=/dev/null bash "$here/download-models.sh" > /dev/null 2>&1 || true
check "no DOWNLOAD_STATUS: no status file" [ ! -e "$status" ]
PATH="$T/bin:$PATH" MANIFEST="$manifest" MODELS_DIR="$T/models" DOWNLOAD_STATUS="$status" DOWNLOAD_DRY_RUN=1 bash "$here/download-models.sh" > /dev/null 2>&1
check "dry run: no status file" [ ! -e "$status" ]

echo
if [ "$fails" = 0 ]; then echo "== download status test passed"; else echo "== download status test: $fails check(s) FAILED"; exit 1; fi
