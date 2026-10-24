#!/usr/bin/env bash
# The pod image's container test (no GPU, no hub, nothing paid): CI runs it on the image it just pushed
# (.github/workflows/build.yml job `test`); by hand: scripts/container-test.sh ghcr.io/angelmankel/imagelab-pod:<tag>.
#
# What it proves (Server #197, gpu-agent DESIGN §10.2 step 5):
#   1. the image carries /usr/local/bin/gpu-agent at the Dockerfile's GPU_AGENT_TAG and no imagelab-agent;
#   2. agent.sh writes gpu-agent.yaml from the env: 2 links + 2 engines, the legacy pair -> 1 lab link, nothing -> off,
#      IMAGELAB_WORKER_TOKEN_2 -> a warning; no token value ever appears in the output; the agent accepts the file;
#   3. download-models.sh: MODEL_PACKS picks the manifests (3d = 11 files), a tiny manifest downloads with a sha256 check,
#      a wrong hash is refused, an existing file is never overwritten;
#   4. start.sh (a CPU boot, no network): both ComfyUIs run at nice 10, the agent at 0 (Server #202, gpu-agent DESIGN §8.2).
#
# DOCKER_RUN_ARGS adds `docker run` options, e.g. bind mounts to try this repo's scripts on an older image before CI:
#   DOCKER_RUN_ARGS="-v $PWD/agent.sh:/opt/imagelab/agent.sh:ro -v ..." scripts/container-test.sh <image>
set -euo pipefail
IMAGE=${1:?usage: container-test.sh <image>}
here=$(cd "$(dirname "$0")/.." && pwd)
TAG=${GPU_AGENT_TAG:-$(sed -n 's/^ARG GPU_AGENT_TAG=//p' "$here/Dockerfile")}
# shellcheck disable=SC2206
EXTRA=(${DOCKER_RUN_ARGS:-})
fails=0
run() {  # run <name> [docker env/opts...] -- <bash script>: runs it in a throwaway container, keeps the output in $out and the code in $code
  local name=$1; shift
  local opts=() net=(--network host)
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); [[ "$1" == --network* ]] && net=(); shift; done
  shift
  set +e
  out=$(docker run --rm "${net[@]}" --entrypoint bash "${EXTRA[@]}" "${opts[@]}" "$IMAGE" -c "$1" 2>&1); code=$?
  set -e
  echo "--- $name (exit $code)"; echo "$out" | sed 's/^/    /' | head -${SHOW_LINES:-40}
}
check() {  # check <description> <condition...>
  local what=$1; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$1" <<< "$out"; }      # fixed strings: the log lines have [brackets]
lacks() { ! grep -qF -- "$1" <<< "$out"; }
hasline() { grep -qx -- "$1" <<< "$out"; }

echo "== image $IMAGE (gpu-agent pin $TAG)"

# ---- 1. the agent binary ---------------------------------------------------------------------------------
run "gpu-agent --version" -- '/usr/local/bin/gpu-agent --version; test -e /usr/local/bin/imagelab-agent && echo IMAGELAB_AGENT_PRESENT || echo no-imagelab-agent'
check "gpu-agent --version is the pinned build +$TAG" grep -qE "^gpu-agent [0-9]+\.[0-9]+\.[0-9]+\+$TAG\$" <<< "$out"
check "no imagelab-agent in the image" has "no-imagelab-agent"

# ---- 2. agent.sh -------------------------------------------------------------------------------------------
# Fake tokens (random, this run only) so the test can prove they never leak into the output or the file.
T_LAB=fake-lab-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'); T_DEV=fake-dev-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
run "agent.sh: two tokens, two ComfyUIs" -e GPU_AGENT_TOKEN_LAB="$T_LAB" -e GPU_AGENT_TOKEN_MAPS_DEV="$T_DEV" -e WORKER_COST_PER_HOUR=1.5 -e AGENT_CONFIG_ONLY=1 -- \
  '/opt/imagelab/agent.sh 8189 8191'
check "exit 0" [ "$code" = 0 ]
check "link lab -> agents host" has "id: lab, app: imagelab, url: wss://agents.blueoceanswim.com/lab/agent, token: env:GPU_AGENT_TOKEN_LAB, priority: 10"
check "link maps-dev -> agents host, priority 0" has "id: maps-dev, app: mapmaker, url: wss://agents.blueoceanswim.com/maps-dev/agent, token: env:GPU_AGENT_TOKEN_MAPS_DEV, priority: 0"
check "no maps link without its token" lacks "id: maps,"
check "engine comfy0 on gpu 0 at :8189" has "url: http://127.0.0.1:8189"
check "engine comfy1 on gpu 1 at :8191" has "url: http://127.0.0.1:8191"
check "two engines" [ "$(grep -c 'engine: comfy' <<< "$out")" = 2 ]
check "gpu 1 for the second" has "gpu: 1"
check "inputDir / outputDir (#187)" has "inputDir: /workspace/ComfyUI/input"
check "control attach on a pod" has "control: { mode: attach, pod: true, imageManaged: true }"
check "modelsMarker = the models-complete file start.sh touches (#202)" [ "$(grep -c 'modelsMarker: /workspace/imagelab-logs/models-complete' <<< "$out")" = 2 ]
check "costPerHour from WORKER_COST_PER_HOUR" has "costPerHour: 1.5"
check "no token value in the output" lacks "$T_LAB"
check "no token value in the output (dev)" lacks "$T_DEV"

run "agent.sh: the agent accepts the file (URLs pointed at a closed port; killed after 8 s = it was running)" \
  -e GPU_AGENT_TOKEN_LAB="$T_LAB" -e GPU_AGENT_TOKEN_MAPS_DEV="$T_DEV" -e GPU_AGENT_URL_LAB=ws://127.0.0.1:9/agent -e GPU_AGENT_URL_MAPS_DEV=ws://127.0.0.1:9/agent \
  -e AGENT_CONFIG_ONLY=1 -- \
  '/opt/imagelab/agent.sh 8189 8191 >/dev/null; export WORKER_POD=1 LOG_FORMAT=text; timeout 8 /usr/local/bin/gpu-agent --config /etc/gpu-agent/gpu-agent.yaml; echo "agent exit $?"'
check "agent ran until the timeout (124), so the yaml parsed" has "agent exit 124"
check "agent saw both links and both engines" has "engines: comfy0=comfy@gpu0, comfy1=comfy@gpu1"
check "no token value in the agent's log" lacks "$T_LAB"

run "agent.sh: one ComfyUI, one link" -e GPU_AGENT_TOKEN_LAB="$T_LAB" -e AGENT_CONFIG_ONLY=1 -- '/opt/imagelab/agent.sh 8189'
check "one engine" [ "$(grep -c 'engine: comfy' <<< "$out")" = 1 ]
check "one link" has "1 link(s), 1 engine(s)"

run "agent.sh: legacy pair" -e IMAGELAB_SERVER_URL=wss://agents.blueoceanswim.com/lab/agent -e IMAGELAB_WORKER_TOKEN="$T_LAB" -e IMAGELAB_WORKER_TOKEN_2="$T_DEV" -e WORKER_COST_PER_HOUR_2=2 -e AGENT_CONFIG_ONLY=1 -- \
  '/opt/imagelab/agent.sh 8189 8191'
check "legacy lab link from IMAGELAB_SERVER_URL + IMAGELAB_WORKER_TOKEN" has "id: lab, app: imagelab, url: wss://agents.blueoceanswim.com/lab/agent, token: env:IMAGELAB_WORKER_TOKEN, priority: 10"
check "exactly one link" has "1 link(s), 2 engine(s)"
check "IMAGELAB_WORKER_TOKEN_2 warned" has "WARN IMAGELAB_WORKER_TOKEN_2 is ignored"
check "WORKER_COST_PER_HOUR_2 warned" has "WARN WORKER_COST_PER_HOUR_2 is ignored"
check "no token value in the output" lacks "$T_LAB"

run "agent.sh: no token" -- '/opt/imagelab/agent.sh 8189; echo "exit $?"; test -e /etc/gpu-agent/gpu-agent.yaml && echo YAML_WRITTEN || echo no-yaml'
check "[agent] off" has "[agent] off"
check "exit 0" has "exit 0"
check "nothing written" has "no-yaml"

# ---- 3. download-models.sh ----------------------------------------------------------------------------------
run "download-models.sh: MODEL_PACKS=3d lists the 11 files (dry run)" -e MODEL_PACKS=3d -e DOWNLOAD_DRY_RUN=1 -e MODELS_DIR=/tmp/models -- '/opt/imagelab/download-models.sh'
check "11 files in 3d.tsv" has "11 file(s) in the selected manifests"
check "all 11 would be fetched" has "dry run: 11 file(s) would be downloaded"
check "the ultratex decoder is one of them" has "fetch   ultratex/ultratex_flux1_decoder.pt"

run "download-models.sh: default pack is image; an unknown pack is skipped" -e MODEL_PACKS=image,nope -e DOWNLOAD_DRY_RUN=1 -e MODELS_DIR=/tmp/models -- '/opt/imagelab/download-models.sh; echo "exit $?"'
check "unknown pack warned, not fatal" has "unknown pack 'nope'"
check "image pack read" has "packs: image,nope -> /opt/imagelab/packs/image.tsv"
check "exit 0" has "exit 0"

# A tiny real manifest: two public files of a few hundred bytes (1038lab/BiRefNet config files, also rows of image.tsv).
GOOD='url	folder	name	bytes	sha256
https://huggingface.co/1038lab/BiRefNet/resolve/main/config.json	t197/a	config.json	402	966a1f0165b072d2d1309756e71907750e535ba5c3790d8cd0e69713ff3a56cd
https://huggingface.co/1038lab/BiRefNet/resolve/main/BiRefNet_config.py	t197/b	BiRefNet_config.py	298	e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52'
BAD='url	folder	name	bytes	sha256
https://huggingface.co/1038lab/BiRefNet/resolve/main/config.json	t197/c	config.json	402	0000000000000000000000000000000000000000000000000000000000000000'
run "download-models.sh: a 2-file manifest downloads, checks, then is all present; a wrong hash is refused; an existing file is kept" \
  -e GOOD="$GOOD" -e BAD="$BAD" -e MODELS_DIR=/tmp/models -e DOWNLOAD_PARALLEL=2 -- '
    printf "%s\n" "$GOOD" > /tmp/good.tsv; printf "%s\n" "$BAD" > /tmp/bad.tsv
    mkdir -p /tmp/models/t197/b && echo "mine" > /tmp/models/t197/b/BiRefNet_config.py
    echo "## run 1"; MANIFEST=/tmp/good.tsv /opt/imagelab/download-models.sh; echo "exit $?"
    echo "## run 2"; MANIFEST=/tmp/good.tsv /opt/imagelab/download-models.sh; echo "exit $?"
    echo "## bad";   MANIFEST=/tmp/bad.tsv /opt/imagelab/download-models.sh; echo "exit $?"
    echo "## files"; sha256sum /tmp/models/t197/a/config.json; cat /tmp/models/t197/b/BiRefNet_config.py; ls -la /tmp/models/t197/c/ 2>&1'
check "the missing file was added" has "added   t197/a/config.json"
check "its sha256 matches the manifest" has "966a1f0165b072d2d1309756e71907750e535ba5c3790d8cd0e69713ff3a56cd  /tmp/models/t197/a/config.json"
check "the existing file was kept, not overwritten" has "kept    t197/b/BiRefNet_config.py (5 bytes, manifest says 298; add-only, not touched)"
check "existing content unchanged" hasline "mine"
check "run 1 verified" has "all files verified"
check "run 2: everything present" has "everything present"
check "wrong hash refused" has "sha256 mismatch for t197/c/config.json"
check "wrong hash: the run fails (start.sh retries)" has "exit 1"
check "no .part left in the bad folder" [ "$(grep -A3 '## files' <<< "$out" | grep -c 'config.json')" = 1 ]

# ---- 4. CPU priority: ComfyUI below the agent (#202) ------------------------------------------------------------
# A real boot on the CPU without network: both ComfyUIs (COMFY_VIDEO=1) and the agent (a fake token, hub at a closed
# port; AGENT_WAIT_TRIES=1 so it does not wait for ComfyUI's imports). Nice from /proc (no procps in the image).
run "start.sh: ComfyUI runs at a lower CPU priority than the agent" --network none \
  -e SKIP_MODEL_DOWNLOAD=1 -e SKIP_LLM=1 -e COMFY_VIDEO=1 -e COMFY_ARGS=--cpu -e AGENT_WAIT_TRIES=1 \
  -e GPU_AGENT_TOKEN_LAB="$T_LAB" -e GPU_AGENT_URL_LAB=ws://127.0.0.1:9/agent -- '
    /opt/imagelab/start.sh > /tmp/start.log 2>&1 &
    pid_of() { for d in /proc/[0-9]*; do c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null); case "$c" in "$1"*) echo "${d#/proc/}"; return;; esac; done; }
    nice_of() { awk "{print \$19}" "/proc/$1/stat"; }
    for _ in $(seq 1 150); do
      img=$(pid_of "python main.py --listen 127.0.0.1 --port 8189"); vid=$(pid_of "python main.py --listen 127.0.0.1 --port 8191")
      agent=$(pid_of "/usr/local/bin/gpu-agent --config")
      [ -n "$img" ] && [ -n "$vid" ] && [ -n "$agent" ] && break
      sleep 2
    done
    echo "nice comfy0=$(nice_of "${img:-0}" 2>/dev/null) comfy1=$(nice_of "${vid:-0}" 2>/dev/null) agent=$(nice_of "${agent:-0}" 2>/dev/null)"
    grep -F "(nice 10)" /tmp/start.log'
check "the image ComfyUI (:8189) at nice 10" has "comfy0=10 "
check "the video ComfyUI (:8191) at nice 10" has "comfy1=10 "
check "the agent at nice 0" has "agent=0"
check "start.sh logs the nice" has "(nice 10)"
check "no token value in the boot output" lacks "$T_LAB"

echo
if [ "$fails" = 0 ]; then echo "== container test passed"; else echo "== container test: $fails check(s) FAILED"; exit 1; fi
