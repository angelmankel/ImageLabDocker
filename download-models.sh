#!/usr/bin/env bash
# Adds the models of the selected packs to ${MODELS_DIR:-/workspace/ComfyUI/models}, in parallel with aria2c.
#
# Which files: MODEL_PACKS (comma separated, default `image`) names manifests in packs/ (image.tsv,
# video.tsv, 3d.tsv = Map Maker's duel-maps deploy/models/3d.tsv); MANIFEST=<file> replaces the packs
# with one custom list (a trimmed one for a test pod). A manifest row is `url  folder  name  bytes  sha256`
# (tab separated; a header row, blank lines and # comments are skipped; an old 4-column row has no hash).
#
# Add-only, as the model copy of gpu-agent DESIGN §8.1 / imagelab-server #175: a file that already has its
# name is never touched, whatever its size (logged when it differs). Anything else downloads as <name>.part,
# is checked for bytes and sha256, and only then gets its name; a wrong hash is refused and the part deleted.
# Re-runs resume partial downloads (aria2's control file sits beside the .part).
#
# Exit 0 = every file of the manifests is present and verified. start.sh then touches
# /workspace/imagelab-logs/models-complete (= /pod/logs/models-complete), which the agent watches
# (`modelsMarker` in gpu-agent.yaml, written by agent.sh): it re-reads the model list at once and the hubs
# see the new models within a few seconds (gpu-agent 0.1.3, Server #202). Files that land before that
# are picked up by the agent's 60 s check.
#
# Tokens: `civitai:<versionId>` rows need CIVITAI_API_KEY; HF_TOKEN (optional) is sent to huggingface.co only,
# for gated files (3d.tsv's flux-2-klein-9b-fp8). Both only ever go into a mode-600 temp file and the request.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
MODELS_DIR=${MODELS_DIR:-/workspace/ComfyUI/models}
PACKS_DIR=${PACKS_DIR:-$here/packs}
PARALLEL=${DOWNLOAD_PARALLEL:-6}

# ---- which manifests --------------------------------------------------------------------------------
manifests=()
if [ -n "${MANIFEST:-}" ]; then
  [ -f "$MANIFEST" ] || { echo "[models] !! MANIFEST=$MANIFEST does not exist" >&2; exit 1; }
  manifests+=("$MANIFEST")
  echo "[models] manifest: $MANIFEST (MODEL_PACKS ignored)"
else
  IFS=',' read -r -a packs <<< "${MODEL_PACKS:-image}"
  for p in "${packs[@]}"; do
    p=$(echo "$p" | tr -d '[:space:]'); [ -n "$p" ] || continue
    if [ -f "$PACKS_DIR/$p.tsv" ]; then manifests+=("$PACKS_DIR/$p.tsv")
    else echo "[models] !! unknown pack '$p' (have: $(cd "$PACKS_DIR" && ls *.tsv | sed 's/\.tsv$//' | tr '\n' ' ')); skipped" >&2; fi
  done
  echo "[models] packs: ${MODEL_PACKS:-image} -> ${manifests[*]:-nothing}"
fi

# ---- read the rows ----------------------------------------------------------------------------------
urls=(); folders=(); names=(); sizes=(); shas=()
declare -A seen
for m in "${manifests[@]}"; do
  while IFS=$'\t' read -r url folder name size sha _; do
    [ -n "${url:-}" ] || continue
    case "$url" in \#*) continue ;; url) continue ;; esac
    if [ -z "${folder:-}" ] || [ -z "${name:-}" ] || ! [[ "${size:-}" =~ ^[0-9]+$ ]]; then
      echo "[models] !! bad row in $m: '$url'" >&2; continue
    fi
    sha=$(echo "${sha:-}" | tr 'A-F' 'a-f'); [ -n "$sha" ] || sha=-
    key="$folder/$name"
    if [ -n "${seen[$key]:-}" ]; then
      [ "${seen[$key]}" = "$size" ] || echo "[models] !! $key is listed twice with different sizes ($size vs ${seen[$key]}); the first row wins" >&2
      continue
    fi
    seen[$key]=$size
    urls+=("$url"); folders+=("$folder"); names+=("$name"); sizes+=("$size"); shas+=("$sha")
  done < "$m"
done
echo "[models] ${#urls[@]} file(s) in the selected manifests"

mkdir -p "$MODELS_DIR"
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
input="$work/aria2.input"

real_url() {  # real_url <manifest url>: the URL to fetch (`civitai:<versionId>` carries the API key)
  case "$1" in
    civitai:*) echo "https://civitai.com/api/download/models/${1#civitai:}?token=${CIVITAI_API_KEY:-}" ;;
    *) echo "$1" ;;
  esac
}
civitai_warned=0  # said once, and only when a civitai row is actually missing
hf_header() {  # prints the Authorization header for huggingface.co URLs when HF_TOKEN is set, else nothing
  case "$1" in https://huggingface.co/*) [ -z "${HF_TOKEN:-}" ] || echo "Authorization: Bearer $HF_TOKEN" ;; esac
}

# finish_part <i>: the downloaded <name>.part becomes <name> if its bytes and sha256 are right. 0 = the file is in place.
finish_part() {
  local i=$1 dir path part actual got
  dir="$MODELS_DIR/${folders[$i]}"; path="$dir/${names[$i]}"; part="$path.part"
  if [ -f "$path" ]; then rm -f "$part" "$part.aria2"; return 0; fi   # appeared meanwhile (another run): keep it, never overwrite
  [ -f "$part" ] || return 1
  [ -f "$part.aria2" ] && return 1                                   # aria2 is not done with it; resumes next run
  actual=$(stat -c %s "$part")
  if [ "$actual" != "${sizes[$i]}" ]; then
    echo "[models] !! size mismatch for ${folders[$i]}/${names[$i]} ($actual != ${sizes[$i]}); removed" >&2
    rm -f "$part"; return 1
  fi
  if [ "${shas[$i]}" != - ]; then
    got=$(sha256sum "$part" | cut -d' ' -f1)
    if [ "$got" != "${shas[$i]}" ]; then
      echo "[models] !! sha256 mismatch for ${folders[$i]}/${names[$i]} (got ${got:0:12}..., want ${shas[$i]:0:12}...); refused and removed" >&2
      rm -f "$part"; return 1
    fi
  fi
  mv -n "$part" "$path"                      # -n: if the name appeared since the check, that file stays and the part goes
  if [ -f "$part" ]; then rm -f "$part"; return 0; fi
  echo "[models] added   ${folders[$i]}/${names[$i]}$([ "${shas[$i]}" = - ] && echo ' (size checked, no sha256 in the manifest)')"
}

# ---- what is missing --------------------------------------------------------------------------------
todo=()
for i in "${!urls[@]}"; do
  dir="$MODELS_DIR/${folders[$i]}"; path="$dir/${names[$i]}"
  mkdir -p "$dir"
  if [ -f "$path" ]; then
    actual=$(stat -c %s "$path")
    if [ "$actual" = "${sizes[$i]}" ]; then echo "[models] ok      ${folders[$i]}/${names[$i]}"
    else echo "[models] kept    ${folders[$i]}/${names[$i]} ($actual bytes, manifest says ${sizes[$i]}; add-only, not touched)"; fi
    continue
  fi
  # a complete .part from an interrupted run only needs its check
  if [ -f "$path.part" ] && [ ! -f "$path.part.aria2" ] && finish_part "$i"; then continue; fi
  todo+=("$i")
  echo "[models] fetch   ${folders[$i]}/${names[$i]} (${sizes[$i]} bytes)"
  case "${urls[$i]}" in civitai:*)
    if [ -z "${CIVITAI_API_KEY:-}" ] && [ "$civitai_warned" = 0 ]; then
      echo "[models] WARNING: CIVITAI_API_KEY is empty; Civitai downloads will fail" >&2; civitai_warned=1
    fi ;;
  esac
  {
    printf '%s\n  dir=%s\n  out=%s.part\n' "$(real_url "${urls[$i]}")" "$dir" "${names[$i]}"
    h=$(hf_header "${urls[$i]}"); [ -z "$h" ] || printf '  header=%s\n' "$h"
  } >> "$input"
done

if [ ${#todo[@]} = 0 ]; then
  echo "[models] everything present"
  exit 0
fi
if [ "${DOWNLOAD_DRY_RUN:-0}" = 1 ]; then   # the container test: what would be fetched, nothing downloaded
  echo "[models] dry run: ${#todo[@]} file(s) would be downloaded"
  exit 0
fi

# ---- aria2, then the check of each file ------------------------------------------------------------------
echo "[models] downloading ${#todo[@]} file(s) with aria2c ($PARALLEL concurrent, 8 connections each)"
aria2c --input-file="$input" \
  --max-concurrent-downloads="$PARALLEL" \
  --max-connection-per-server=8 --split=8 --min-split-size=8M \
  --continue=true --allow-overwrite=true --auto-file-renaming=false \
  --file-allocation=none --max-tries=10 --retry-wait=10 --timeout=60 \
  --summary-interval=60 --console-log-level=notice --show-console-readout=false \
  --user-agent="Mozilla/5.0 (imagelab)" \
  || echo "[models] aria2c reported failures; falling back to curl for whatever is still missing" >&2
rm -f "$input"
left=()
for i in "${todo[@]}"; do finish_part "$i" || left+=("$i"); done

# ---- curl fallback (single connection, minimal headers) for files aria2 could not fetch -------------------------
if [ ${#left[@]} -gt 0 ]; then
  echo "[models] curl fallback for ${#left[@]} file(s)"
  pids=()
  for i in "${left[@]}"; do
    path="$MODELS_DIR/${folders[$i]}/${names[$i]}"
    rm -f "$path.part" "$path.part.aria2"
    (
      hdr=(); h=$(hf_header "${urls[$i]}"); [ -z "$h" ] || hdr=(-H "$h")
      code=$(curl -sS -L --retry 3 --retry-delay 5 --max-time 3600 -A "Mozilla/5.0 (imagelab)" "${hdr[@]}" \
               -o "$path.part" -w "%{http_code}" "$(real_url "${urls[$i]}")" 2>>"$work/curl-errors.log" || true)
      if [ "$code" = 200 ]; then finish_part "$i" || echo "[models] curl FAILED ${folders[$i]}/${names[$i]} (http 200 but the file did not check out)" >&2
      else
        echo "[models] curl FAILED ${folders[$i]}/${names[$i]} (http $code, $(stat -c %s "$path.part" 2>/dev/null || echo 0) bytes)" >&2
        rm -f "$path.part"
      fi
    ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  [ -s "$work/curl-errors.log" ] && { echo "[models] curl stderr:"; tail -20 "$work/curl-errors.log"; }
fi

# ---- verify ----------------------------------------------------------------------------------------------
bad=0
for i in "${!urls[@]}"; do
  path="$MODELS_DIR/${folders[$i]}/${names[$i]}"
  [ -f "$path" ] || { echo "[models] FAILED  ${folders[$i]}/${names[$i]}" >&2; bad=$((bad+1)); }
done
[ "$bad" = 0 ] && echo "[models] all files verified" || { echo "[models] $bad file(s) missing" >&2; exit 1; }
