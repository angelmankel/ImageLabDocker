#!/usr/bin/env bash
# Pull every generated image off a pod before it is terminated.
#
#   scripts/pull-images.sh 1.2.3.4:12322 [dest]
#
# Default dest: /mnt/games/images/runpod/MM-DD-YYYY/ — today's date, because a pod's images are a
# day's work and that is how they are looked for later.
#
# A pod's disk does not survive termination, and nothing on it is backed up anywhere. This is the
# last chance. Run it BEFORE `podTerminate`, every time, no exceptions.
#
# Two sources, because neither is complete on its own:
#   /history                 every prompt this ComfyUI has run, with the images each produced.
#                            The app saves through PreviewImage, so these live in temp/ and
#                            ComfyUI wipes temp/ on its next start — they are gone after a resume.
#   /imagelab/api/favorites      anything explicitly starred, copied out of temp/ into a dated tree by
#                            ImageLabCore. These survive a restart but not a terminate.
set -euo pipefail

HOSTPORT="${1:?usage: pull-images.sh <ip:port> [dest]}"
BASE="http://${HOSTPORT}"
DEST="${2:-/mnt/games/images/runpod/$(date +%m-%d-%Y)}"
# One .env for the whole project, beside the three repos.
ENVFILE="${IMAGELAB_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.env}"

set -a; . "$ENVFILE"; set +a
AUTH="${COMFY_LOCAL_USER}:${COMFY_LOCAL_TOKEN}"

mkdir -p "$DEST"
echo "pulling from $BASE into $DEST"

got=0; skip=0; fail=0
save() {  # save <url> <filename>
  local url="$1" name="$2" out="$DEST/$2"
  if [ -s "$out" ]; then skip=$((skip+1)); return; fi
  if curl -sSf -u "$AUTH" -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
    got=$((got+1)); printf '  got  %s\n' "$name"
  else
    rm -f "$out"; fail=$((fail+1)); printf '  FAIL %s\n' "$name"
  fi
}

echo "-- from /history --"
# One request for the whole history; jq flattens every output image of every prompt.
# jq builds the whole query string, already URI-encoded. An earlier version split a @tsv row with
# `read`, which silently ate the empty subfolder: tab counts as whitespace to `read`, so runs of
# tabs collapse and every field shifts left — the type ended up in `subfolder` and the request
# 400'd. Both fields below are always non-empty, so the single separator is safe.
curl -sS -u "$AUTH" "${BASE}/history" \
  | jq -r '.[] | .outputs // {} | .[] | .images // [] | .[]
           | "filename=\(.filename|@uri)&subfolder=\((.subfolder // "")|@uri)&type=\((.type // "output")|@uri)\t\(.filename)"' \
  | sort -u \
  | while IFS=$'\t' read -r query filename; do
      [ -n "$filename" ] || continue
      save "${BASE}/view?${query}" "$filename"
    done

echo "-- from /imagelab/api/favorites --"
# 404 is fine: it only means this pod's image predates ImageLabCore.
if curl -sSf -u "$AUTH" -o /tmp/favs.json "${BASE}/imagelab/api/favorites" 2>/dev/null; then
  jq -r '.favorites[]? | select(.filename)
         | "date=\((.date // "")|@uri)&filename=\(.filename|@uri)\tfav-\(.date // "undated")-\(.filename)"' /tmp/favs.json \
    | while IFS=$'\t' read -r query name; do
        [ -n "$name" ] || continue
        save "${BASE}/imagelab/api/favorites/view?${query}" "$name"
      done
  rm -f /tmp/favs.json
else
  echo "  (no favorites endpoint on this pod)"
fi

# The subshells above have their own counters, so count what is actually on disk instead.
echo "$DEST now holds $(find "$DEST" -type f | wc -l) file(s)"
du -sh "$DEST" 2>/dev/null || true
