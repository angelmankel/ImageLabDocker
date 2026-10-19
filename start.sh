#!/usr/bin/env bash
# Container entrypoint: persist models on /workspace, download what is missing, run ComfyUI behind nginx basic auth.
set -euo pipefail
MODELS_DIR=${MODELS_DIR:-/workspace/ComfyUI/models}
COMFY_PORT=${COMFY_PORT:-8189}
PROXY_PORT=${PROXY_PORT:-8188}
APP_PORT=${IMAGELAB_APP_PORT:-8190}
LLM_PORT=${LLM_PORT:-11434}
VIDEO_PORT=${COMFY_VIDEO_PORT:-8191}
COMFY_AUTH_USER=${COMFY_AUTH_USER:-imagelab}
COMFY_ARGS=${COMFY_ARGS:-}

if [ -z "${COMFY_AUTH_TOKEN:-}" ]; then
  COMFY_AUTH_TOKEN=$(openssl rand -hex 16)
  echo "[start] COMFY_AUTH_TOKEN not set; generated one: $COMFY_AUTH_TOKEN"
fi

# ---- models live on the (persistent) workspace volume ------------------------------
mkdir -p "$MODELS_DIR"
if [ ! -L /opt/ComfyUI/models ]; then
  # seed the standard folder layout (and configs like extra_model_paths) then swap in a symlink
  cp -rn /opt/ComfyUI/models/. "$MODELS_DIR"/ 2>/dev/null || true
  rm -rf /opt/ComfyUI/models
  ln -s "$MODELS_DIR" /opt/ComfyUI/models
fi
mkdir -p "$MODELS_DIR/controlnet_aux_ckpts"
aux=/opt/ComfyUI/custom_nodes/comfyui_controlnet_aux
if [ -d "$aux" ] && [ ! -L "$aux/ckpts" ]; then
  rm -rf "$aux/ckpts"; ln -s "$MODELS_DIR/controlnet_aux_ckpts" "$aux/ckpts"
fi
mkdir -p "$MODELS_DIR/wd14_tagger"
wd=/opt/ComfyUI/custom_nodes/ComfyUI-WD14-Tagger
if [ -d "$wd" ] && [ ! -L "$wd/models" ]; then
  rm -rf "$wd/models"; ln -s "$MODELS_DIR/wd14_tagger" "$wd/models"
fi
# ---- ImageLabCore on the volume, so it can be changed without an image rebuild ------
# Same trade the app already makes: a custom node baked into the image costs a ten minute build
# and a pod resume for every one-line change. On the volume it can be written to while the pod
# runs, and ComfyUI re-execs in place (POST /manager/reboot) to pick it up — about thirty seconds,
# no container restart, no new port, Traefik untouched.
#
# Seeded from the image only when the volume copy is absent, exactly as live.py seeds the app: once
# it exists, the volume is the truth and a later image never overwrites work in progress. To take
# the image's version again, delete /workspace/ImageLabCore and restart.
NODE_DIR=${IMAGELAB_NODE_DIR:-/workspace/ImageLabCore}
BAKED=/opt/ComfyUI/custom_nodes/ImageLabCore
if [ ! -d "$NODE_DIR" ]; then
  mkdir -p "$NODE_DIR"
  cp -a "$BAKED/." "$NODE_DIR"/ 2>/dev/null || true
  echo "[start] seeded $NODE_DIR from the image"
fi
if [ ! -L "$BAKED" ]; then
  rm -rf "$BAKED"
  ln -s "$NODE_DIR" "$BAKED"
fi
# A .pyc from a previous boot shadows a file edited since; cheap to drop, confusing to debug.
find "$NODE_DIR" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "[start] ImageLabCore: $BAKED -> $NODE_DIR"

mkdir -p /workspace/ComfyUI/output /workspace/ComfyUI/input
for d in output input; do
  if [ ! -L /opt/ComfyUI/$d ]; then
    cp -rn /opt/ComfyUI/$d/. /workspace/ComfyUI/$d/ 2>/dev/null || true
    rm -rf /opt/ComfyUI/$d; ln -s /workspace/ComfyUI/$d /opt/ComfyUI/$d
  fi
done

# ComfyUI's user dir holds saved workflows and settings. In the image layer a STOP wipes it, so it
# lives on the volume like output/ and input/. Workflows shipped in the image (this repo's
# workflows/) are copied in only when missing: one saved on the pod always wins.
mkdir -p /workspace/ComfyUI/user/default/workflows
if [ ! -L /opt/ComfyUI/user ]; then
  cp -rn /opt/ComfyUI/user/. /workspace/ComfyUI/user/ 2>/dev/null || true
  rm -rf /opt/ComfyUI/user; ln -s /workspace/ComfyUI/user /opt/ComfyUI/user
fi
cp -rn /opt/imagelab/workflows/. /workspace/ComfyUI/user/default/workflows/ 2>/dev/null || true

# ---- reverse proxy with basic auth --------------------------------------------------
mkdir -p /tmp/nginx-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
printf '%s:%s\n' "$COMFY_AUTH_USER" "$(openssl passwd -apr1 "$COMFY_AUTH_TOKEN")" > /tmp/htpasswd
# COMFY_AUTH_ALIASES: extra user names, space-separated, same password. For a browser or proxy
# that still has an older user name saved; set it in the pod env, never bake it in.
for alias in ${COMFY_AUTH_ALIASES:-}; do
  printf '%s:%s\n' "$alias" "$(openssl passwd -apr1 "$COMFY_AUTH_TOKEN")" >> /tmp/htpasswd
done
sed -e "s/\${PROXY_PORT}/$PROXY_PORT/g" -e "s/\${COMFY_PORT}/$COMFY_PORT/g" -e "s/\${APP_PORT}/$APP_PORT/g" -e "s/\${LLM_PORT}/$LLM_PORT/g" -e "s/\${VIDEO_PORT}/$VIDEO_PORT/g" /opt/imagelab/nginx.conf.template > /tmp/nginx.conf

# Check the generated config before trusting it. nginx is the only way in — ComfyUI, ImageLab and
# the log endpoints all sit behind it — so a config it refuses would leave a running, billing pod
# with nothing answering and no shell to fix it from. If the template is bad, fall back to a
# minimal proxy that still serves ComfyUI with its basic auth, and say so loudly in the log.
if ! nginx -t -c /tmp/nginx.conf 2>/tmp/nginx-test.log; then
  echo "[start] !! nginx REJECTED the generated config — falling back to a minimal proxy"
  sed 's/^/[start]    /' /tmp/nginx-test.log
  cat > /tmp/nginx.conf <<NGINX
worker_processes 1;
daemon off;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;
events { worker_connections 256; }
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  access_log /dev/stdout;
  client_body_temp_path /tmp/nginx-body;
  proxy_temp_path /tmp/nginx-proxy;
  client_max_body_size 0;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen 0.0.0.0:$PROXY_PORT;
    auth_basic "imagelab";
    auth_basic_user_file /tmp/htpasswd;
    location / {
      proxy_pass http://127.0.0.1:$COMFY_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 3600s;
      proxy_buffering off;
    }
  }
}
NGINX
fi
nginx -c /tmp/nginx.conf &
echo "[start] nginx listening on 0.0.0.0:$PROXY_PORT (basic auth user '$COMFY_AUTH_USER') -> 127.0.0.1:$COMFY_PORT"

# ---- models (background, retried; log served at /pod/logs/download.log through the proxy) ----
LOG_DIR=/workspace/imagelab-logs
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR/models-complete"   # stale marker from a previous boot must not report completion
if [ "${SKIP_MODEL_DOWNLOAD:-0}" != 1 ]; then
  (
    for attempt in $(seq 1 "${DOWNLOAD_ATTEMPTS:-20}"); do
      echo "[models] ===== attempt $attempt $(date -u +%FT%TZ) ====="
      if /opt/imagelab/download-models.sh; then
        echo "[models] ===== complete $(date -u +%FT%TZ) ====="
        touch "$LOG_DIR/models-complete"
        exit 0
      fi
      echo "[models] attempt $attempt failed; retrying in 30s"
      sleep 30
    done
    echo "[models] ===== GAVE UP after ${DOWNLOAD_ATTEMPTS:-20} attempts ====="
  ) 2>&1 | tee -a "$LOG_DIR/download.log" &
fi

# ---- the pod's own LLM server (Ollama), served at /llm/ ------------------------------------------
# An optional second AI server for ImageLab, beside the LAN one (winold): the pod has the VRAM. The
# 1.4 GB release goes onto the volume once per version rather than into the image, so the image
# pull stays fast and a stop keeps it; models live on the volume too. Ollama takes no VRAM until a
# model is used, and lets it go after OLLAMA_KEEP_ALIVE. SKIP_LLM=1 turns it off. Log:
# /pod/logs/llm.log.
OLLAMA_VERSION=${OLLAMA_VERSION:-0.40.6}
LLM_DIR=/workspace/ollama
if [ "${SKIP_LLM:-0}" != 1 ]; then
  (
    set +e
    if [ "$(cat "$LLM_DIR/.version" 2>/dev/null)" != "$OLLAMA_VERSION" ]; then
      echo "installing Ollama $OLLAMA_VERSION"
      rm -rf "$LLM_DIR/dist.new" && mkdir -p "$LLM_DIR/dist.new"
      for attempt in 1 2 3 4 5; do
        curl -fsSL "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-linux-amd64.tar.zst" \
          | tar --zstd -x -C "$LLM_DIR/dist.new" && break
        echo "download attempt $attempt failed; retrying in 20s"; sleep 20
      done
      if [ -x "$LLM_DIR/dist.new/bin/ollama" ]; then
        rm -rf "$LLM_DIR/dist" && mv "$LLM_DIR/dist.new" "$LLM_DIR/dist" && echo "$OLLAMA_VERSION" > "$LLM_DIR/.version"
      fi
    fi
    export OLLAMA_HOST=127.0.0.1:$LLM_PORT OLLAMA_MODELS=$LLM_DIR/models OLLAMA_ORIGINS='*' \
      OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE:-10m}
    while [ -x "$LLM_DIR/dist/bin/ollama" ]; do
      "$LLM_DIR/dist/bin/ollama" serve
      echo "ollama exited ($?); restarting in 5s"; sleep 5
    done
    echo "no Ollama binary; /llm/ stays down"
  ) 2>&1 | tee -a "$LOG_DIR/llm.log" | sed -u 's/^/[llm] /' &
fi

# ---- the live app on the volume (hot reload; only this supervisor is baked) ----------------------
python /opt/imagelab/live.py 2>&1 | sed -u 's/^/[app] /' &
echo "[start] live app supervisor on 127.0.0.1:$APP_PORT, code at ${IMAGELAB_APP_DIR:-/workspace/imagelab-app} (served at /pod/app)"

# ---- ComfyUI, and a second one for video at /video-comfy/ -------------------------------------
# A Wan render holds a ComfyUI for minutes and its queue is a single line, so images wait behind
# it. A second ComfyUI on 127.0.0.1:$VIDEO_PORT takes the video. It runs from the same /opt/ComfyUI,
# so models, input, output, custom nodes (ImageLabCore too) and the user dir with the saved
# workflows are shared through the symlinks above. What each keeps to itself:
#   temp/        ComfyUI wipes it at start, and ImageLab saves through PreviewImage into it: one
#                restarting must not eat the other's images. --temp-directory (ComfyUI adds /temp).
#   database     ComfyUI locks user/comfyui.db for one process. The second gets an in-memory one;
#                it only holds the assets index, which is off.
#   ImageLabCore IMAGELAB_CORE_SECONDARY=1: no hash scan, no sort, no downloads, favorites only.
#                nginx sends its other /imagelab/api/* to the first. IMAGELAB_AUTO_DOWNLOAD is
#                blanked too, for an ImageLabCore on the volume older than that switch.
#
# On by default when GPU 0 has 80 GB or more (A100/H100 80 GB, H200, B200); a 5090 has no room for
# two. COMFY_VIDEO=1 / 0 forces it. Log: /pod/logs/comfy-video.log.
#
# VRAM: ComfyUI assumes it owns the GPU. Its dynamic VRAM (comfy-aimdo, on by default here) caps
# a process's own allocations at total - --reserve-vram and evicts its own weights (they stream
# from RAM instead) when the device runs low; it never takes memory back from the other process,
# and an idle ComfyUI keeps its weights resident. So each one reserves the other's share: video
# gets 55% of (total - 4 GB), images the rest, and the 4 GB covers what aimdo does not count (two
# CUDA contexts, onnxruntime in the background-removal and tagger nodes). COMFY_VIDEO_VRAM_GB moves
# the split; a --reserve-vram in COMFY_ARGS / COMFY_VIDEO_ARGS overrides it (the last flag wins).
GPU_MIB=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc 0-9 || true)
GPU_MIB=${GPU_MIB:-0}
case "${COMFY_VIDEO:-auto}" in
  1|true|yes|on)  VIDEO_ON=1 ;;
  0|false|no|off) VIDEO_ON=0 ;;
  *) if [ "$GPU_MIB" -ge 80000 ]; then VIDEO_ON=1; else VIDEO_ON=0; fi ;;
esac
IMAGE_VRAM_ARGS=""; VIDEO_VRAM_ARGS=""
if [ "$VIDEO_ON" = 1 ] && [ "$GPU_MIB" -gt 0 ]; then
  # prints: images' --reserve-vram, video's --reserve-vram, video share, images share (GB)
  read -r IMAGE_RESERVE VIDEO_RESERVE VIDEO_GB IMAGE_GB < <(awk -v mib="$GPU_MIB" -v want="${COMFY_VIDEO_VRAM_GB:-}" 'BEGIN {
    t = mib / 1024; slack = 4; free = t - slack
    v = (want != "") ? want + 0 : int(free * 0.55)
    if (v > free - 4) v = free - 4; if (v < 4) v = 4
    i = free - v
    printf "%.1f %.1f %.1f %.1f\n", v + slack, i + slack, v, i }')
  IMAGE_VRAM_ARGS="--reserve-vram $IMAGE_RESERVE"
  VIDEO_VRAM_ARGS="--reserve-vram $VIDEO_RESERVE"
fi

cd /opt/ComfyUI
VIDEO_DIR=/opt/comfy-video   # its temp/; container disk, like the first one's
if [ "$VIDEO_ON" = 1 ]; then
  echo "[start] video ComfyUI on 127.0.0.1:$VIDEO_PORT (served at /video-comfy/); GPU ${GPU_MIB} MiB, video ${VIDEO_GB:-?} GB / images ${IMAGE_GB:-?} GB"
  (
    set +e
    echo "===== boot $(date -u +%FT%TZ): GPU ${GPU_MIB} MiB, video ${VIDEO_GB:-?} GB, images ${IMAGE_GB:-?} GB ====="
    # Start once the first one answers. Both import every custom node and several packs write
    # their config files while importing; staggered, the first has also run the DB migration and
    # ImageLabCore's checkpoint sort, and the RAM peak of two loads does not land at once.
    for _ in $(seq 1 120); do
      curl -fs -o /dev/null -m 5 "http://127.0.0.1:$COMFY_PORT/system_stats" && break
      sleep 5
    done
    mkdir -p "$VIDEO_DIR"
    while true; do
      echo "starting $(date -u +%FT%TZ)"
      IMAGELAB_CORE_SECONDARY=1 IMAGELAB_AUTO_DOWNLOAD= python main.py --listen 127.0.0.1 --port "$VIDEO_PORT" \
        --preview-method taesd --temp-directory "$VIDEO_DIR" --database-url sqlite:///:memory: \
        $VIDEO_VRAM_ARGS ${COMFY_VIDEO_ARGS:-}
      echo "exited ($?); restarting in 5s"; sleep 5
    done
  ) 2>&1 | tee -a "$LOG_DIR/comfy-video.log" | sed -u 's/^/[video] /' &
else
  echo "[start] video ComfyUI off (GPU ${GPU_MIB} MiB, COMFY_VIDEO=${COMFY_VIDEO:-auto}); /video-comfy/ answers 502" \
    | tee -a "$LOG_DIR/comfy-video.log"
fi

echo "[start] ComfyUI $(cat .pinned-commit 2>/dev/null) on 127.0.0.1:$COMFY_PORT ${IMAGE_VRAM_ARGS}"
exec python main.py --listen 127.0.0.1 --port "$COMFY_PORT" --preview-method taesd $IMAGE_VRAM_ARGS $COMFY_ARGS
