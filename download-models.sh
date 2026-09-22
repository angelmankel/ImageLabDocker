#!/usr/bin/env bash
# Downloads every entry of models.txt into ${MODELS_DIR:-/workspace/ComfyUI/models}, all in parallel with aria2c.
# Files that already exist with the expected size are skipped. Re-runs resume partial downloads.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
MANIFEST=${MANIFEST:-$here/models.txt}
MODELS_DIR=${MODELS_DIR:-/workspace/ComfyUI/models}
PARALLEL=${DOWNLOAD_PARALLEL:-6}

if [ -z "${CIVITAI_API_KEY:-}" ]; then
  echo "[models] WARNING: CIVITAI_API_KEY is empty; Civitai downloads will fail" >&2
fi

mkdir -p "$MODELS_DIR"
input=$(mktemp)
missing=0

while IFS=$'\t' read -r url folder name size; do
  [ -z "$url" ] && continue
  case "$url" in \#*) continue ;; esac
  dir="$MODELS_DIR/$folder"
  path="$dir/$name"
  mkdir -p "$dir"
  if [ -f "$path" ] && [ ! -f "$path.aria2" ]; then
    actual=$(stat -c %s "$path")
    if [ "$actual" = "$size" ]; then
      echo "[models] ok      $folder/$name"
      continue
    fi
    echo "[models] size mismatch for $folder/$name ($actual != $size), re-downloading"
    rm -f "$path"
  fi
  case "$url" in
    civitai:*) url="https://civitai.com/api/download/models/${url#civitai:}?token=${CIVITAI_API_KEY:-}" ;;
  esac
  missing=$((missing+1))
  echo "[models] fetch   $folder/$name ($size bytes)"
  printf '%s\n  dir=%s\n  out=%s\n' "$url" "$dir" "$name" >> "$input"
done < "$MANIFEST"

if [ "$missing" = 0 ]; then
  echo "[models] everything present"
  rm -f "$input"
  exit 0
fi

echo "[models] downloading $missing file(s) with aria2c ($PARALLEL concurrent, 8 connections each)"
aria2c --input-file="$input" \
  --max-concurrent-downloads="$PARALLEL" \
  --max-connection-per-server=8 --split=8 --min-split-size=8M \
  --continue=true --allow-overwrite=true --auto-file-renaming=false \
  --file-allocation=none --max-tries=10 --retry-wait=10 --timeout=60 \
  --summary-interval=60 --console-log-level=notice --show-console-readout=false \
  --user-agent="Mozilla/5.0 (imagelab)" \
  || echo "[models] aria2c reported failures; falling back to curl for whatever is still missing" >&2
rm -f "$input"

# curl fallback (single connection, minimal headers) for files aria2 could not fetch
pids=()
while IFS=$'\t' read -r url folder name size; do
  [ -z "$url" ] && continue
  case "$url" in \#*) continue ;; esac
  path="$MODELS_DIR/$folder/$name"
  if [ -f "$path" ] && [ ! -f "$path.aria2" ] && [ "$(stat -c %s "$path")" = "$size" ]; then continue; fi
  case "$url" in
    civitai:*) url="https://civitai.com/api/download/models/${url#civitai:}?token=${CIVITAI_API_KEY:-}" ;;
  esac
  rm -f "$path" "$path.aria2"
  (
    code=$(curl -sS -L --retry 3 --retry-delay 5 --max-time 3600 -A "Mozilla/5.0 (imagelab)" \
             -o "$path.part" -w "%{http_code}" "$url" 2>>"$MODELS_DIR/.curl-errors.log" || true)
    if [ "$code" = 200 ] && [ "$(stat -c %s "$path.part" 2>/dev/null)" = "$size" ]; then
      mv "$path.part" "$path"; echo "[models] curl ok  $folder/$name"
    else
      echo "[models] curl FAILED $folder/$name (http $code, $(stat -c %s "$path.part" 2>/dev/null || echo 0) bytes)" >&2
      rm -f "$path.part"
    fi
  ) &
  pids+=($!)
done < "$MANIFEST"
[ ${#pids[@]} -gt 0 ] && { echo "[models] curl fallback for ${#pids[@]} file(s)"; wait "${pids[@]}"; }
[ -s "$MODELS_DIR/.curl-errors.log" ] && { echo "[models] curl stderr:"; tail -20 "$MODELS_DIR/.curl-errors.log"; rm -f "$MODELS_DIR/.curl-errors.log"; }

# verify sizes
bad=0
while IFS=$'\t' read -r url folder name size; do
  [ -z "$url" ] && continue
  case "$url" in \#*) continue ;; esac
  path="$MODELS_DIR/$folder/$name"
  if [ ! -f "$path" ] || [ "$(stat -c %s "$path")" != "$size" ]; then
    echo "[models] FAILED  $folder/$name" >&2; bad=$((bad+1))
  fi
done < "$MANIFEST"
[ "$bad" = 0 ] && echo "[models] all files verified" || { echo "[models] $bad file(s) missing/incomplete" >&2; exit 1; }
