#!/usr/bin/env bash
# Push ImageLabCore to a running pod and restart ComfyUI in place.
#
#   scripts/push-node.sh 1.2.3.4:10012
#
# Custom nodes normally live in the image, which makes a one-line change a ten minute rebuild and
# a pod resume. start.sh keeps this one on the volume instead, so it can be written to live; the
# restart is ComfyUI re-exec'ing itself, not the container going down — the PID is preserved, the
# public port does not change, and Traefik never needs touching. About thirty seconds.
#
# Source is ~/Github/ImageLabCore. Auth comes from ../.env beside the three repos.
set -euo pipefail

HOSTPORT="${1:?usage: push-node.sh <ip:port>}"
BASE="http://${HOSTPORT}"
SRC="${IMAGELAB_CORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../ImageLabCore" 2>/dev/null && pwd)}"
# One .env for the whole project, beside the three repos.
ENVFILE="${IMAGELAB_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.env}"

[ -d "$SRC" ] || { echo "no source at $SRC"; exit 1; }
set -a; . "$ENVFILE"; set +a
AUTH="${COMFY_LOCAL_USER}:${COMFY_LOCAL_TOKEN}"

ok=0; fail=0
# Only what ComfyUI actually imports. The repo also carries modules that are not loaded and a design
# note; shipping those to the pod just makes the next person wonder which file is live.
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
    --data-binary "@$f" "${BASE}/pod/app/api/node?path=$(printf %s "$rel" | jq -sRr @uri)")
  if [ "$code" = "200" ]; then ok=$((ok+1)); printf '  ok   %s\n' "$rel"
  else fail=$((fail+1)); printf '  FAIL %s (HTTP %s)\n' "$rel" "$code"; fi
done < <(find "$SRC" -name '*.py' -not -path '*/.git/*' -not -path '*/__pycache__/*' -print0)

echo "pushed $ok file(s), $fail failure(s)"
[ "$fail" -eq 0 ] || exit 1

echo "restarting ComfyUI in place ..."
# 502 is the expected answer: nginx sees ComfyUI vanish mid-request, and it is already re-exec'ing.
curl -sS -o /dev/null -w '  /manager/reboot -> HTTP %{http_code}\n' -m 20 \
  -u "$AUTH" -X POST -H 'Content-Type: application/json' -d '{}' "${BASE}/manager/reboot" || true

for i in $(seq 1 40); do
  sleep 3
  if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u "$AUTH" "${BASE}/imagelab/hashes")" = "200" ]; then
    echo "  ComfyUI back after ~$((i*3))s, /imagelab/hashes answering"
    exit 0
  fi
done
echo "  ComfyUI did not come back within 120s — check the pod log" >&2
exit 1
