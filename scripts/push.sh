#!/usr/bin/env bash
# Push app/ and ../ImageLab/dist to a running pod through its own file API (/pod/app/api/files).
# The app lives on the volume at /workspace/imagelab-app and live.py hot-reloads it, so no image rebuild.
#
#   scripts/push.sh 1.2.3.4:10695
#
# Auth comes from ../.env beside the three repos (COMFY_LOCAL_USER / COMFY_LOCAL_TOKEN).
set -euo pipefail

HOSTPORT="${1:?usage: push.sh <ip:port>}"
BASE="http://${HOSTPORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="${IMAGELAB_WEB_DIR:-$(cd "$ROOT/../ImageLab" 2>/dev/null && pwd)}"
# One .env for the whole project, beside the three repos.
ENVFILE="${IMAGELAB_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.env}"

set -a; . "$ENVFILE"; set +a
AUTH="${COMFY_LOCAL_USER}:${COMFY_LOCAL_TOKEN}"

ok=0; fail=0
while IFS= read -r -d '' f; do
  rel="${f#"$ROOT"/app/}"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
    --data-binary "@$f" "${BASE}/pod/app/api/files?path=$(printf %s "$rel" | jq -sRr @uri)")
  if [ "$code" = "200" ]; then
    ok=$((ok+1)); printf '  ok   %s\n' "$rel"
  else
    fail=$((fail+1)); printf '  FAIL %s (HTTP %s)\n' "$rel" "$code"
  fi
done < <(find "$ROOT/app" -type f -not -path '*/__pycache__/*' -print0)

# The web app lives in the sibling ImageLab repo. Its built dist/ is what the pod serves, so it is
# pushed from there rather than kept as a second copy in this repo that could drift.
if [ -n "${WEB:-}" ] && [ -d "$WEB/dist" ]; then
  while IFS= read -r -d '' f; do
    rel="lab/${f#"$WEB"/dist/}"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
      --data-binary "@$f" "${BASE}/pod/app/api/files?path=$(printf %s "$rel" | jq -sRr @uri)")
    if [ "$code" = "200" ]; then ok=$((ok+1)); printf '  ok   %s\n' "$rel"
    else fail=$((fail+1)); printf '  FAIL %s (HTTP %s)\n' "$rel" "$code"; fi
  done < <(find "$WEB/dist" -type f -print0)
else
  echo "  (no ImageLab/dist beside this repo — run npm run build there first)" >&2
fi

echo "pushed $ok file(s), $fail failure(s) -> ${BASE}/pod/app/lab/"
[ "$fail" -eq 0 ]
