# ComfyUI image for ImageLab (RTX 5090 / Blackwell ready).
# CUDA 12.8 + torch 2.8.0 cu128 wheels; ComfyUI and every custom node pinned to a commit.
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common curl ca-certificates gnupg \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-dev \
        git aria2 nginx-light openssl build-essential \
        libgl1 libglib2.0-0 libgomp1 libsm6 libxext6 \
    && rm -rf /var/lib/apt/lists/* \
    && python3.11 -m venv /opt/venv \
    && pip install --upgrade pip wheel setuptools

# Torch first, from the cu128 index, so nothing below can drag in a CPU/other-CUDA build.
RUN pip install torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 \
        --index-url https://download.pytorch.org/whl/cu128

# ---- ComfyUI (pinned) -------------------------------------------------------
ARG COMFYUI_REF=v0.34.5
RUN git clone --depth 1 --branch ${COMFYUI_REF} https://github.com/Comfy-Org/ComfyUI /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && pip install -r requirements.txt \
    && git rev-parse HEAD > /opt/ComfyUI/.pinned-commit

# ---- Custom node packs (pinned commits) --------------------------------------
COPY install-node.sh /usr/local/bin/install-node
RUN chmod +x /usr/local/bin/install-node \
    && install-node https://github.com/evanspearman/ComfyMath           c01177221c31b8e5fbc062778fc8254aeb541638 ComfyMath \
    && install-node https://github.com/1038lab/ComfyUI-RMBG              58f1947a11567a9f8b707223185570850e773856 ComfyUI-RMBG \
    && install-node https://github.com/chflame163/ComfyUI_LayerStyle     5ba939099b33f998ecfbd63dcbbf089925b64a47 ComfyUI_LayerStyle \
    && install-node https://github.com/Fannovel16/comfyui_controlnet_aux 59b1fc411ede8623b2997855b8018f0b3b6cf49f comfyui_controlnet_aux

# ---- Anime-workstation packs (pinned). skip_download_model stops Impact-Pack's install.py from
#      fetching SAM into the image (models come from models.txt onto the volume instead).
RUN touch /opt/ComfyUI/custom_nodes/skip_download_model \
    && install-node https://github.com/Comfy-Org/ComfyUI-Manager               f82970b7cb63ad44928308f980a1d38fda103cbb ComfyUI-Manager \
    && install-node https://github.com/ltdrdata/ComfyUI-Impact-Pack            429d0159ad429e64d2b3916e6e7be9c22d025c3c ComfyUI-Impact-Pack \
    && install-node https://github.com/ltdrdata/ComfyUI-Impact-Subpack         50c7b71a6a224734cc9b21963c6d1926816a97f1 ComfyUI-Impact-Subpack \
    && install-node https://github.com/ltdrdata/ComfyUI-Inspire-Pack           d23db9aa544de9a6d4c609cb7005fa9e0d42031d ComfyUI-Inspire-Pack \
    && install-node https://github.com/cubiq/ComfyUI_essentials                9d9f4bedfc9f0321c19faf71855e228c93bd0dc9 ComfyUI_essentials \
    && install-node https://github.com/kijai/ComfyUI-KJNodes                   da90cca857d7dd6fb615015197f99845e72c9bd3 ComfyUI-KJNodes \
    && install-node https://github.com/rgthree/rgthree-comfy                   2c5342a8cb0eaecaabf61435a5f37dd594c510ba rgthree-comfy \
    && install-node https://github.com/pythongosssss/ComfyUI-Custom-Scripts    609f3afaa74b2f88ef9ce8d939626065e3247469 ComfyUI-Custom-Scripts \
    && install-node https://github.com/pythongosssss/ComfyUI-WD14-Tagger       9e0a6e700299182fc05c58b62e7ad9f72182a78b ComfyUI-WD14-Tagger \
    && install-node https://github.com/ssitu/ComfyUI_UltimateSDUpscale         a5547db9e1d07d3318bb21e9e9c474f4c1e9c8df ComfyUI_UltimateSDUpscale \
    && install-node https://github.com/cubiq/ComfyUI_IPAdapter_plus            a0f451a5113cf9becb0847b92884cb10cbdec0ef ComfyUI_IPAdapter_plus \
    && install-node https://github.com/storyicon/comfyui_segment_anything      ab6395596399d5048639cdab7e44ec9fae857a93 comfyui_segment_anything \
    && install-node https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes    d78b780ae43fcf8c6b7c6505e6ffb4584281ceca ComfyUI_Comfyroll_CustomNodes \
    && install-node https://github.com/WASasquatch/was-node-suite-comfyui      c5ff955029829755807a52ac5bc5ebc8410cde6c was-node-suite-comfyui \
    && install-node https://github.com/yolain/ComfyUI-Easy-Use                 271685698b0935c5b0ecca86a58c3817931cd205 ComfyUI-Easy-Use

# Re-assert the CUDA torch build and the GPU onnxruntime (several packs pull the CPU 'onnxruntime',
# which shadows onnxruntime-gpu's providers), then prove CUDA 12.8 + the GPU provider are what's left.
RUN pip install torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 \
        --index-url https://download.pytorch.org/whl/cu128 \
    && pip uninstall -y onnxruntime onnxruntime-gpu || true \
    && pip install "onnxruntime-gpu>=1.19" \
    && python -c "import torch, sys; print('torch', torch.__version__, 'cuda', torch.version.cuda); sys.exit(0 if torch.version.cuda and torch.version.cuda.startswith('12.8') else 1)" \
    && python -c "import onnxruntime as ort, sys; p=ort.get_available_providers(); print('ort', ort.__version__, p); sys.exit(0 if 'CUDAExecutionProvider' in p else 1)"

# ---- ImageLabCore: the API the front end talks to ---------------------------------
# This is what answers /imagelab/api/hashes, /imagelab/api/downloads and /imagelab/api/favorites. Without it
# the app cannot ask a server what models it has, and the model browser shows nothing. Pinned like
# every other pack above.
RUN install-node https://github.com/angelmankel/ImageLabCore 329f9926e8192ee39216d988022bf6371d4c8f45 ImageLabCore

# ---- Runtime files --------------------------------------------------------------
COPY models.txt download-models.sh start.sh nginx.conf.template live.py /opt/imagelab/
COPY app /opt/imagelab/app
COPY workflows /opt/imagelab/workflows

# ---- ImageLab, the web front end ---------------------------------------------------
# The built dist/ is cloned at a pin. dist/ is committed there precisely so this needs no npm in the image build. What lands here is
# only the seed: scripts/push.sh replaces it on a running pod without a rebuild.
RUN git clone --depth 1 https://github.com/angelmankel/ImageLab /tmp/imagelab \
    && git -C /tmp/imagelab fetch --depth 1 origin df7939017b45b4e221772443f6723fd0e5a31922 \
    && git -C /tmp/imagelab checkout --quiet df7939017b45b4e221772443f6723fd0e5a31922 \
    && mkdir -p /opt/imagelab/app/lab \
    && cp -a /tmp/imagelab/dist/. /opt/imagelab/app/lab/ \
    && rm -rf /tmp/imagelab
RUN chmod +x /opt/imagelab/download-models.sh /opt/imagelab/start.sh

ENV MODELS_DIR=/workspace/ComfyUI/models \
    IMAGELAB_APP_DIR=/workspace/imagelab-app \
    IMAGELAB_NODE_DIR=/workspace/ImageLabCore \
    IMAGELAB_APP_PORT=8190 \
    COMFY_PORT=8189 \
    PROXY_PORT=8188 \
    COMFY_AUTH_USER=imagelab

EXPOSE 8188
WORKDIR /opt/ComfyUI
CMD ["/opt/imagelab/start.sh"]
