#!/usr/bin/env bash
# Container entrypoint: persist models on /workspace, download what is missing, run ComfyUI behind nginx basic auth.
set -euo pipefail
MODELS_DIR=${MODELS_DIR:-/workspace/ComfyUI/models}
COMFY_PORT=${COMFY_PORT:-8189}
PROXY_PORT=${PROXY_PORT:-8188}
APP_PORT=${IMAGELAB_APP_PORT:-8190}
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
sed -e "s/\${PROXY_PORT}/$PROXY_PORT/g" -e "s/\${COMFY_PORT}/$COMFY_PORT/g" -e "s/\${APP_PORT}/$APP_PORT/g" /opt/imagelab/nginx.conf.template > /tmp/nginx.conf

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

# ---- the live app on the volume (hot reload; only this supervisor is baked) ----------------------
python /opt/imagelab/live.py 2>&1 | sed -u 's/^/[app] /' &
echo "[start] live app supervisor on 127.0.0.1:$APP_PORT, code at ${IMAGELAB_APP_DIR:-/workspace/imagelab-app} (served at /pod/app)"

# ---- ComfyUI ----------------------------------------------------------------------------------
cd /opt/ComfyUI
echo "[start] ComfyUI $(cat .pinned-commit 2>/dev/null) on 127.0.0.1:$COMFY_PORT"
exec python main.py --listen 127.0.0.1 --port "$COMFY_PORT" --preview-method taesd $COMFY_ARGS
