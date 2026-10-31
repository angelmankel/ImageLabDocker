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
# (`modelsMarker` in gpu-agent.yaml, written by agent.sh): it re-reads the model list at once, then every 3 s
# until ImageLabCore has indexed (its scan runs every 30 s) and hashed every file, so the hubs see each new
# model within ~3 s of ImageLabCore listing it (gpu-agent 0.1.4, Server #202). Files that land before that
# are picked up by the agent's 60 s check, which opens the same 3 s window.
#
# Tokens: `civitai:<versionId>` rows need CIVITAI_API_KEY; HF_TOKEN (optional) is sent to huggingface.co only,
# for gated files (3d.tsv's flux-2-klein-9b-fp8). Both only ever go into a mode-600 temp file and the request.
#
# ImageLab's Download queue (gpu-agent 0.1.5): with DOWNLOAD_STATUS=<file> (start.sh: /pod/logs/startup-downloads.tsv,
# deleted at boot) every change of a file to fetch is appended there as one tab-separated line, which the agent reads
# (`startupDownloads` in gpu-agent.yaml) and sends to the hubs as download.progress:
#   run <id>                                       once, when the file is new: every attempt of one boot shares it
#   queued <folder> <name> <bytes> <path>          to be fetched (again: each queued line starts an attempt; the curl
#                                                  fallback writes one too, as it fetches the file again from zero)
#   done   <folder> <name> <bytes> <path>          checked and in place under its name
#   failed <folder> <name> <bytes> <path> <why>    not fetched by this attempt (start.sh tries again)
# Each file is checked as soon as aria2 has it (aria2 runs this script as its --on-download-complete hook), so it
# lands, and shows done, without waiting for the rest of the batch.
#
# Progress (gpu-agent 0.1.6): with DOWNLOAD_RPC_FILE=<file> as well (start.sh: /run/imagelab/aria2-rpc.json, outside
# the nginx-served logs) aria2c runs with its JSON-RPC on 127.0.0.1:${ARIA2_RPC_PORT:-6801} only and a random secret,
# and the script writes {"url","secret"} to that file (mode 600) while aria2 runs; the agent (`startupDownloadsRpc`)
# asks aria2 for each file's completedLength. Without it the agent reads aria2's control file (<path>.part.aria2,
# saved every 10 s), or the .part's size for curl. With RPC aria2 does not exit by itself, so this script calls
# aria2.shutdown once nothing is active or waiting; the run then goes on (checks, curl fallback) exactly as before.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
MODELS_DIR=${MODELS_DIR:-/workspace/ComfyUI/models}
PACKS_DIR=${PACKS_DIR:-$here/packs}
PARALLEL=${DOWNLOAD_PARALLEL:-6}
STATUS=${DOWNLOAD_STATUS:-}
[ "${DOWNLOAD_DRY_RUN:-0}" = 1 ] && STATUS=   # the container test's dry run reports nothing
RPC_FILE=${DOWNLOAD_RPC_FILE:-}
RPC_PORT=${ARIA2_RPC_PORT:-6801}
[ -n "$STATUS" ] || RPC_FILE=                 # nobody shows the progress without the status file
urls=(); folders=(); names=(); sizes=(); shas=()

status() {  # status <state> <i> [why]: one line for the agent (see above); nothing without DOWNLOAD_STATUS
  [ -n "$STATUS" ] || return 0
  local why=${3:-}
  why=$(printf '%s' "$why" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s%s\n' "$1" "${folders[$2]}" "${names[$2]}" "${sizes[$2]}" "$MODELS_DIR/${folders[$2]}/${names[$2]}" \
    "${why:+$(printf '\t%s' "$why")}" >> "$STATUS" 2>/dev/null || true
}

# finish_part <i>: the downloaded <name>.part becomes <name> if its bytes and sha256 are right. 0 = the file is in place.
# One check per file at a time: aria2's completion hook and the run's own pass after aria2 may meet on the same file.
finish_part() {
  if [ -n "${DL_WORK:-}" ] && [ -d "$DL_WORK" ] && command -v flock >/dev/null 2>&1; then
    ( flock 9; finish_part_now "$1" ) 9>"$DL_WORK/lock.$1"
  else
    finish_part_now "$1"
  fi
}
finish_part_now() {
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
  status done "$i"
}

# ---- aria2's --on-download-complete hook: <gid> <number of files> <path of the .part> -------------------------------
# Run by aria2 (asynchronously) for each finished file, with this run's rows in $DL_WORK/rows.tsv. It checks that one
# file now; anything it cannot settle (aria2 still holding the control file, a bad hash) the run's own pass after
# aria2 takes over, as before.
if [ -n "${DL_WORK:-}" ] && [ $# = 3 ]; then
  [ -f "$DL_WORK/rows.tsv" ] || exit 0
  done_part=$(readlink -m -- "$3")
  while IFS=$'\t' read -r i folder name size sha path; do
    [ "$(readlink -m -- "$path.part")" = "$done_part" ] || continue
    folders[$i]=$folder; names[$i]=$name; sizes[$i]=$size; shas[$i]=$sha
    for _ in $(seq 1 30); do [ -f "$3.aria2" ] || break; sleep 1; done   # aria2 drops its control file as it finishes
    finish_part "$i" || true
    break
  done < "$DL_WORK/rows.tsv"
  exit 0
fi

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
if [ -n "$STATUS" ] && [ ! -s "$STATUS" ]; then   # before the umask: nginx serves it as /pod/logs/startup-downloads.tsv
  mkdir -p "$(dirname "$STATUS")" && printf 'run\t%s\n' "${DOWNLOAD_RUN:-$(date +%s)}" > "$STATUS" || STATUS=
fi
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"; [ -z "$RPC_FILE" ] || rm -f "$RPC_FILE"' EXIT
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
  status queued "$i"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "${folders[$i]}" "${names[$i]}" "${sizes[$i]}" "${shas[$i]}" "$dir/${names[$i]}" >> "$work/rows.tsv"
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
export DL_WORK="$work" MODELS_DIR DOWNLOAD_STATUS="$STATUS"   # for the hook below (this script again)
# RPC for the agent's progress (see the top): loopback only, the secret only in mode-600 files (not on a command line).
rpc_opts=() secret=
if [ -n "$RPC_FILE" ]; then
  if (exec 3<>"/dev/tcp/127.0.0.1/$RPC_PORT") 2>/dev/null; then
    echo "[models] port $RPC_PORT is taken; aria2 runs without RPC (progress from its control files)" >&2; RPC_FILE=
  else
    secret=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf 'enable-rpc=true\nrpc-listen-all=false\nrpc-listen-port=%s\nrpc-secret=%s\n' "$RPC_PORT" "$secret" > "$work/aria2.conf"
    rpc_opts=(--conf-path="$work/aria2.conf" --stop-with-process=$$)
    mkdir -p "$(dirname "$RPC_FILE")" \
      && printf '{"url":"http://127.0.0.1:%s/jsonrpc","secret":"%s"}\n' "$RPC_PORT" "$secret" > "$RPC_FILE.tmp" \
      && mv -f "$RPC_FILE.tmp" "$RPC_FILE" || { rm -f "$RPC_FILE.tmp"; RPC_FILE=; }
  fi
fi
rpc() {  # rpc <method> [<json params after the token>]: aria2's answer on stdout; the secret goes in on stdin
  printf '{"jsonrpc":"2.0","id":"m","method":"%s","params":["token:%s"%s]}' "$1" "$secret" "${2:+,$2}" |
    curl -s -m 5 -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$RPC_PORT/jsonrpc"
}
num() { sed -n "s/.*\"$1\" *: *\"\([0-9]*\)\".*/\1/p" <<< "$2"; }   # num <key> <json>: one of aria2's number strings
aria2c --input-file="$input" \
  --on-download-complete="$here/$(basename "$0")" \
  --max-concurrent-downloads="$PARALLEL" \
  --max-connection-per-server=8 --split=8 --min-split-size=8M \
  --continue=true --allow-overwrite=true --auto-file-renaming=false \
  --file-allocation=none --max-tries=10 --retry-wait=10 --timeout=60 --auto-save-interval=10 \
  --summary-interval=60 --console-log-level=notice --show-console-readout=false \
  --user-agent="Mozilla/5.0 (imagelab)" "${rpc_opts[@]}" &
aria2_pid=$!
aria2_errors=0
if [ -n "$secret" ]; then
  # With RPC aria2 keeps running after its input file: shut it down once nothing is active or waiting. Every input
  # row is in aria2's queue before its RPC answers, so 0 + 0 means done (also if aria2 skipped a row it could not
  # use: three idle answers in a row are enough then).
  idle=0 shut=0
  while kill -0 "$aria2_pid" 2>/dev/null; do
    sleep 2
    st=$(rpc aria2.getGlobalStat) || continue
    active=$(num numActive "$st"); waiting=$(num numWaiting "$st"); stopped=$(num numStoppedTotal "$st")
    [ -n "$active" ] && [ -n "$waiting" ] || continue
    if [ "$active" = 0 ] && [ "$waiting" = 0 ]; then idle=$((idle+1)); else idle=0; continue; fi
    [ "${stopped:-0}" -gt 0 ] || [ "$idle" -ge 3 ] || continue
    if [ "$shut" = 0 ]; then aria2_errors=$(rpc aria2.tellStopped '0,1000,["status"]' | grep -o '"status" *: *"error"' | wc -l); shut=1; fi
    rpc aria2.shutdown > /dev/null             # asked again on the next round should this answer get lost
  done
fi
wait "$aria2_pid"; aria2_rc=$?
[ -z "$RPC_FILE" ] || rm -f "$RPC_FILE"
if [ "$aria2_rc" != 0 ] || [ "$aria2_errors" -gt 0 ]; then
  echo "[models] aria2c reported failures; falling back to curl for whatever is still missing" >&2
fi
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
    status queued "$i"                         # a new attempt for the agent: curl starts this file from zero
    (
      hdr=(); h=$(hf_header "${urls[$i]}"); [ -z "$h" ] || hdr=(-H "$h")
      code=$(curl -sS -L --retry 3 --retry-delay 5 --max-time 3600 -A "Mozilla/5.0 (imagelab)" "${hdr[@]}" \
               -o "$path.part" -w "%{http_code}" "$(real_url "${urls[$i]}")" 2>>"$work/curl-errors.log" || true)
      if [ "$code" = 200 ]; then
        finish_part "$i" || { echo "[models] curl FAILED ${folders[$i]}/${names[$i]} (http 200 but the file did not check out)" >&2
                               status failed "$i" "downloaded, but the size or sha256 did not match"; }
      else
        echo "[models] curl FAILED ${folders[$i]}/${names[$i]} (http $code, $(stat -c %s "$path.part" 2>/dev/null || echo 0) bytes)" >&2
        rm -f "$path.part"
        status failed "$i" "http $code"
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
