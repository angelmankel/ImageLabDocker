#!/usr/bin/env bash
# Sync ComfyUI saved workflows between a pod and workflows/ in this repo.
#
#   scripts/workflows.sh pull <ip:port>   # pod -> workflows/   (run before a stop or terminate, then commit)
#   scripts/workflows.sh push <ip:port>   # workflows/ -> pod   (overwrites same-named files on the pod)
#
# Goes through ComfyUI's own /api/userdata, so it is exactly what the ComfyUI menu and ImageLab's
# Studio see. Subfolders are kept. A new pod is seeded from the image's copy of workflows/ at boot
# (start.sh), so push is only needed for changes made here since the image was built.
set -euo pipefail

MODE="${1:?usage: workflows.sh pull|push <ip:port>}"
HOSTPORT="${2:?usage: workflows.sh pull|push <ip:port>}"
BASE="http://${HOSTPORT}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflows"
# One .env for the whole project, beside the three repos.
ENVFILE="${IMAGELAB_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.env}"
set -a; . "$ENVFILE"; set +a
AUTH="${COMFY_LOCAL_USER}:${COMFY_LOCAL_TOKEN}"
enc() { printf %s "$1" | jq -sRr @uri; }

ok=0; fail=0
case "$MODE" in
  pull)
    mkdir -p "$DIR"
    list=$(curl -sS -u "$AUTH" "${BASE}/api/userdata?dir=workflows&recurse=true") || { echo "cannot list workflows" >&2; exit 1; }
    # 404 "Directory not found" just means the pod has none yet.
    echo "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "no workflows on the pod"; exit 0; }
    while IFS= read -r rel; do
      [[ "$rel" == *.json ]] || continue
      mkdir -p "$DIR/$(dirname "$rel")"
      if curl -sSf -u "$AUTH" -o "$DIR/$rel" "${BASE}/api/userdata/$(enc "workflows/$rel")"; then
        ok=$((ok+1)); printf '  got  %s\n' "$rel"
      else fail=$((fail+1)); printf '  FAIL %s\n' "$rel"; fi
    done < <(echo "$list" | jq -r '.[]')
    echo "pulled $ok, $fail failure(s) -> $DIR   (commit them)"
    ;;
  push)
    while IFS= read -r -d '' f; do
      rel="${f#"$DIR"/}"
      code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -X POST --data-binary "@$f" \
        -H 'Content-Type: application/json' "${BASE}/api/userdata/$(enc "workflows/$rel")?overwrite=true&full_info=true")
      if [ "$code" = "200" ]; then ok=$((ok+1)); printf '  ok   %s\n' "$rel"
      else fail=$((fail+1)); printf '  FAIL %s (HTTP %s)\n' "$rel" "$code"; fi
    done < <(find "$DIR" -type f -name '*.json' -print0)
    echo "pushed $ok, $fail failure(s)"
    ;;
  *) echo "usage: workflows.sh pull|push <ip:port>" >&2; exit 1 ;;
esac
[ "$fail" -eq 0 ]
