#!/usr/bin/env bash
# The ImageLab agent: connects this pod's ComfyUI OUT to the ImageLab server over one websocket, so
# the server needs no port of the pod, no Traefik route and no repointing after a resume.
#
# start.sh runs this in the background. It does anything only when the pod env has both
# IMAGELAB_SERVER_URL and IMAGELAB_WORKER_TOKEN. Without them it says so and exits: a pod used on its
# own, and gpu-server, which runs this same image but has its own agent beside it (a second one
# there would register the same ComfyUI twice).
#
# One agent per ComfyUI that start.sh launched, each a worker of its own on the server: the first
# with IMAGELAB_WORKER_TOKEN, the second (COMFY_VIDEO on) with IMAGELAB_WORKER_TOKEN_2. A second
# ComfyUI without that token simply has no agent.
#
# usage: agent.sh <first ComfyUI port> [<second ComfyUI port>]
set -uo pipefail
AGENT_BIN=${IMAGELAB_AGENT_BIN:-/usr/local/bin/imagelab-agent}
LOG_DIR=${LOG_DIR:-/workspace/imagelab-logs}
INPUT_DIR=${COMFY_INPUT_DIR:-/workspace/ComfyUI/input}
LLM_PORT=${LLM_PORT:-11434}
FIRST_PORT=${1:?usage: agent.sh <port> [<second port>]}
SECOND_PORT=${2:-}

if [ -z "${IMAGELAB_SERVER_URL:-}" ] || [ -z "${IMAGELAB_WORKER_TOKEN:-}" ]; then
  echo "[agent] off: IMAGELAB_SERVER_URL and IMAGELAB_WORKER_TOKEN are not both set"
  exit 0
fi
if [ ! -x "$AGENT_BIN" ]; then
  echo "[agent] !! $AGENT_BIN is missing; no agent"
  exit 0
fi
mkdir -p "$LOG_DIR"

# run_agent <tag> <ComfyUI port> <token> <log file> <Ollama URL or off> <cost per hour or "">
run_agent() {
  local tag=$1 port=$2 token=$3 log=$4 ollama=$5 cost=$6
  (
    set +e
    # Exported here, in this subshell only, never on a command line (ps would show it).
    export IMAGELAB_WORKER_TOKEN="$token"
    # ComfyUI straight on its loopback port: no nginx, so no basic auth. The pod's
    # COMFY_AUTH_USER (the image sets it) would otherwise make the agent send a login it does not need.
    unset COMFY_AUTH_USER COMFY_AUTH_TOKEN COMFY_AUTH_ALIASES IMAGELAB_WORKER_TOKEN_2 WORKER_COST_PER_HOUR_2
    export COMFY_URL="http://127.0.0.1:$port" COMFY_INPUT_DIR="$INPUT_DIR" \
      COMFY_CONTROL=attach WORKER_POD=1 OLLAMA_URL="$ollama" LOG_LEVEL="${AGENT_LOG_LEVEL:-info}"
    if [ -n "$cost" ]; then export WORKER_COST_PER_HOUR="$cost"; else unset WORKER_COST_PER_HOUR; fi
    # Start once this ComfyUI answers, as the second ComfyUI waits for the first. The agent would
    # cope with a ComfyUI that is down (it reports "unreachable" and polls), but a worker that shows
    # up before its ComfyUI only gets in the way. After the wait it starts regardless.
    for _ in $(seq 1 "${AGENT_WAIT_TRIES:-120}"); do
      curl -fs -o /dev/null -m 5 "http://127.0.0.1:$port/system_stats" && break
      sleep "${AGENT_WAIT_SECS:-5}"
    done
    while true; do
      echo "===== starting $(date -u +%FT%TZ): $("$AGENT_BIN" --version 2>/dev/null) for ComfyUI 127.0.0.1:$port ====="
      "$AGENT_BIN"
      echo "exited ($?); restarting in ${AGENT_RESTART_SECS:-10}s"; sleep "${AGENT_RESTART_SECS:-10}"
    done
  ) 2>&1 | tee -a "$LOG_DIR/$log" | sed -u "s/^/[$tag] /" &
}

# The pod's Ollama goes to the first worker only: one Ollama, so one worker reports it.
if [ "${SKIP_LLM:-0}" = 1 ]; then llm=off; else llm="http://127.0.0.1:$LLM_PORT"; fi
echo "[agent] -> $IMAGELAB_SERVER_URL: worker 1 for ComfyUI :$FIRST_PORT (log /pod/logs/agent.log)"
run_agent agent "$FIRST_PORT" "$IMAGELAB_WORKER_TOKEN" agent.log "$llm" "${WORKER_COST_PER_HOUR:-}"

if [ -n "$SECOND_PORT" ]; then
  if [ -n "${IMAGELAB_WORKER_TOKEN_2:-}" ]; then
    echo "[agent] -> $IMAGELAB_SERVER_URL: worker 2 for ComfyUI :$SECOND_PORT (log /pod/logs/agent-2.log)"
    run_agent agent-2 "$SECOND_PORT" "$IMAGELAB_WORKER_TOKEN_2" agent-2.log off "${WORKER_COST_PER_HOUR_2:-}"
  else
    echo "[agent] the second ComfyUI (:$SECOND_PORT) has no worker: IMAGELAB_WORKER_TOKEN_2 is not set"
  fi
fi
wait
