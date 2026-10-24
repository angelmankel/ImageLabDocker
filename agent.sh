#!/usr/bin/env bash
# The agent (gpu-agent, donny/gpu-agent apps/agent, DESIGN §8.3 / §10.2 step 5): connects this pod OUT to the
# agent hubs over one websocket per hub, so no hub needs a port of the pod, a Traefik route or a repoint
# after a resume. ONE agent for the whole pod: each ComfyUI start.sh launched is an engine of it
# (`comfy0` = slot gpu0, `comfy1` = slot gpu1), and each hub token in the env is a link.
#
# start.sh runs this in the background. It does anything only when the pod env has a hub token:
# GPU_AGENT_TOKEN_LAB (ImageLab), GPU_AGENT_TOKEN_MAPS (Map Maker), GPU_AGENT_TOKEN_MAPS_DEV (Map Maker dev),
# or the old pair IMAGELAB_SERVER_URL + IMAGELAB_WORKER_TOKEN (the `lab` link, for old RunPod templates).
# Without any it says so and exits: a pod used on its own, and gpu-server, which runs this same image but
# has its own agent beside it (a second one there would register the same ComfyUI twice).
#
# The agent reads /etc/gpu-agent/gpu-agent.yaml, written here from the env at every boot. Tokens never go
# into the file: it says `token: env:GPU_AGENT_TOKEN_LAB` and the agent reads the variable (so the file can
# be printed or served without leaking anything).
#
# usage: agent.sh <first ComfyUI port> [<second ComfyUI port>]
#   AGENT_CONFIG_ONLY=1   write and print the yaml, start nothing (the CI container test)
set -uo pipefail
AGENT_BIN=${GPU_AGENT_BIN:-/usr/local/bin/gpu-agent}
CONFIG_DIR=${GPU_AGENT_CONFIG_DIR:-/etc/gpu-agent}
CONFIG="$CONFIG_DIR/gpu-agent.yaml"
LOG_DIR=${LOG_DIR:-/workspace/imagelab-logs}
INPUT_DIR=${COMFY_INPUT_DIR:-/workspace/ComfyUI/input}
OUTPUT_DIR=${COMFY_OUTPUT_DIR:-/workspace/ComfyUI/output}
LLM_PORT=${LLM_PORT:-11434}
FIRST_PORT=${1:?usage: agent.sh <port> [<second port>]}
SECOND_PORT=${2:-}

# ---- links: one per token in the env (DESIGN §8.3, URLs of §9.1; GPU_AGENT_URL_<X> overrides one) ---------
links=()
add_link() {  # add_link <id> <app> <url> <token variable> <priority>
  links+=("  - { id: $1, app: $2, url: $3, token: env:$4, priority: $5 }")
  echo "[agent] link $1 ($2) -> $3 (token from $4)"
}
[ -z "${GPU_AGENT_TOKEN_LAB:-}" ]      || add_link lab      imagelab "${GPU_AGENT_URL_LAB:-wss://agents.blueoceanswim.com/lab/agent}"           GPU_AGENT_TOKEN_LAB 10
[ -z "${GPU_AGENT_TOKEN_MAPS:-}" ]     || add_link maps     mapmaker "${GPU_AGENT_URL_MAPS:-wss://agents.blueoceanswim.com/maps/agent}"         GPU_AGENT_TOKEN_MAPS 10
[ -z "${GPU_AGENT_TOKEN_MAPS_DEV:-}" ] || add_link maps-dev mapmaker "${GPU_AGENT_URL_MAPS_DEV:-wss://agents.blueoceanswim.com/maps-dev/agent}" GPU_AGENT_TOKEN_MAPS_DEV 0
# Old templates: IMAGELAB_SERVER_URL + IMAGELAB_WORKER_TOKEN make the lab link (unless GPU_AGENT_TOKEN_LAB already did).
if [ -z "${GPU_AGENT_TOKEN_LAB:-}" ] && [ -n "${IMAGELAB_WORKER_TOKEN:-}" ]; then
  if [ -n "${IMAGELAB_SERVER_URL:-}" ]; then add_link lab imagelab "$IMAGELAB_SERVER_URL" IMAGELAB_WORKER_TOKEN 10
  else echo "[agent] !! IMAGELAB_WORKER_TOKEN is set but IMAGELAB_SERVER_URL is not; no lab link" >&2; fi
fi
for old in IMAGELAB_WORKER_TOKEN_2 WORKER_COST_PER_HOUR_2; do
  [ -z "${!old:-}" ] || echo "[agent] WARN $old is ignored: the second ComfyUI is slot gpu1 of the same worker now (gpu-agent DESIGN §8.3)"
done

if [ ${#links[@]} = 0 ]; then
  echo "[agent] off: no GPU_AGENT_TOKEN_LAB / _MAPS / _MAPS_DEV (nor IMAGELAB_SERVER_URL + IMAGELAB_WORKER_TOKEN) in the env"
  exit 0
fi
if [ ! -x "$AGENT_BIN" ]; then
  echo "[agent] !! $AGENT_BIN is missing; no agent" >&2
  exit 0
fi

# ---- engines: one `comfy` per ComfyUI start.sh launched. Straight to the loopback port: no nginx, so no basic auth.
# Slot gpu0 is the image ComfyUI, gpu1 the video one; these are the worker's slots (what a hub dispatches to), not
# nvidia-smi indexes: on a shared card both still run at once, as start.sh set them up. inputDir/outputDir let the
# agent delete a job's inputs and the files its save nodes wrote (#187). modelsMarker: start.sh touches it when the
# model download is complete, and the agent re-sends its model list to every hub at once (gpu-agent 0.1.3, Server
# #202; besides its own 60 s check). control attach + pod: image-managed (the hub's update / install-node are
# refused; restart is ComfyUI-Manager's soft reboot).
engine() {  # engine <id> <gpu> <port>
  cat <<EOF
  - id: $1
    engine: comfy
    gpu: $2
    url: http://127.0.0.1:$3
    inputDir: $INPUT_DIR
    outputDir: $OUTPUT_DIR
    modelsMarker: $LOG_DIR/models-complete
    control: { mode: attach, pod: true, imageManaged: true }
EOF
}
cost=""
if [[ "${WORKER_COST_PER_HOUR:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then cost="costPerHour: $WORKER_COST_PER_HOUR   # the whole pod; the agent splits it over the gpu slots"
elif [ -n "${WORKER_COST_PER_HOUR:-}" ]; then echo "[agent] WARN WORKER_COST_PER_HOUR='$WORKER_COST_PER_HOUR' is not a number; no cost reported" >&2; fi

mkdir -p "$CONFIG_DIR"
{
  echo "# Written by /opt/imagelab/agent.sh from the pod env at $(date -u +%FT%TZ); no token in here (env: references)."
  echo "links:"
  printf '%s\n' "${links[@]}"
  echo "engines:"
  engine comfy0 0 "$FIRST_PORT"
  [ -z "$SECOND_PORT" ] || engine comfy1 1 "$SECOND_PORT"
  [ -z "$cost" ] || echo "$cost"
} > "$CONFIG"
chmod 644 "$CONFIG"
echo "[agent] wrote $CONFIG: ${#links[@]} link(s), $([ -n "$SECOND_PORT" ] && echo 2 || echo 1) engine(s)"
if [ "${AGENT_CONFIG_ONLY:-0}" = 1 ]; then cat "$CONFIG"; exit 0; fi
mkdir -p "$LOG_DIR"

# The pod's Ollama (ImageLab's local LLM helpers) goes through the agent's imagelab extension; one Ollama, reported once.
if [ "${SKIP_LLM:-0}" = 1 ]; then llm=off; else llm="http://127.0.0.1:$LLM_PORT"; fi
echo "[agent] -> ${#links[@]} hub(s) for ComfyUI :$FIRST_PORT${SECOND_PORT:+ and :$SECOND_PORT} (log /pod/logs/agent.log)"
(
  set +e
  # Not for the agent: the pod's nginx login (the agent talks to ComfyUI on loopback) and the old per-worker vars.
  unset COMFY_AUTH_USER COMFY_AUTH_TOKEN COMFY_AUTH_ALIASES IMAGELAB_WORKER_TOKEN_2 WORKER_COST_PER_HOUR_2 WORKER_COST_PER_HOUR
  # WORKER_POD marks the pod for the agent (RunPod also sets RUNPOD_POD_ID); the work folder (job inputs, §6.7) goes
  # on the volume, not the 30 GB container disk.
  export WORKER_POD=1 GPU_AGENT_WORK="${GPU_AGENT_WORK:-/workspace/gpu-agent}" \
    OLLAMA_URL="$llm" LOG_LEVEL="${AGENT_LOG_LEVEL:-info}" LOG_FORMAT="${AGENT_LOG_FORMAT:-text}"
  # Start once the first ComfyUI answers, as the second ComfyUI waits for the first. The agent would cope with a
  # ComfyUI that is down (it reports "unreachable" and polls), but a worker that shows up before its ComfyUI only
  # gets in the way. After the wait it starts regardless.
  for _ in $(seq 1 "${AGENT_WAIT_TRIES:-120}"); do
    curl -fs -o /dev/null -m 5 "http://127.0.0.1:$FIRST_PORT/system_stats" && break
    sleep "${AGENT_WAIT_SECS:-5}"
  done
  while true; do
    echo "===== starting $(date -u +%FT%TZ): $("$AGENT_BIN" --version 2>/dev/null) ====="
    "$AGENT_BIN" --config "$CONFIG"
    echo "exited ($?); restarting in ${AGENT_RESTART_SECS:-10}s"; sleep "${AGENT_RESTART_SECS:-10}"
  done
) 2>&1 | tee -a "$LOG_DIR/agent.log" | sed -u "s/^/[agent] /"
