# ImageLabDocker — the pod image, and the rules for everything around it

**Read this first.** It is the entry point for the whole project. The other two repos point here.

## The project

Three repos, all on GitHub, kept side by side locally in `~/Github/ImageLabProject/`:

| | | |
|---|---|---|
| **ImageLabDocker** | this one | The image: ComfyUI, custom nodes pinned to commits, the model manifest, the pod's own web app, and the scripts that drive a pod. Pushing to `main` builds `ghcr.io/angelmankel/imagelab-pod:latest` through Actions, about ten minutes — but only when a file that goes into the image changes (see `paths:` in `.github/workflows/build.yml`). A README or `scripts/` edit builds nothing. |
| **ImageLabCore** | `../ImageLabCore` | A ComfyUI custom node that adds an HTTP API and no nodes: model hash index, CivitAI downloads, persistent favorites. Cloned into the image at a pin. |
| **ImageLab** | `../ImageLab` | The web front end. Built to a committed `dist/`, cloned into the image at a pin. |

Separate repos on purpose. A ComfyUI custom node has to be its own repo to be installable, and the
image has its own build and release cycle. They are related by living in one folder and by this
document.

## Rules that are not negotiable

1. **Before terminating a pod, pull its images.** `scripts/pull-images.sh <ip:port>` writes to
   `/mnt/games/images/runpod/MM-DD-YYYY/`. A pod's disk is backed up nowhere and a terminate is
   final. Do it before a *resume* too — the app saves through `PreviewImage` into ComfyUI's
   `temp/`, and ComfyUI wipes `temp/` when it starts.
2. **Before terminating a pod, pull its workflows and push all three repos.** `scripts/workflows.sh pull <ip:port>`,
   then `git status` in each repo, commit, push.
3. **Ask before spending GPU.** A pod bills whether or not it renders. Say the hourly rate when
   you start one; stop it when it goes idle.
4. **Every retry is a NEW project. Never overwrite a render.** The failures are the data.
5. **Commit straight to `main`. No branches.**
6. **Every change Donny asks for ships at once, without asking. Always.**
   1. **Pod first.** As soon as the change works, push it to the pod Donny is using now, so Donny
      sees it straight away. Find the pod with `list-pods` (use the running one; ask only if
      there are several). Web changes: `npm run build` in ImageLab, then upload only `dist/` —
      see *How to check and ship* in `../HANDOFF.md` (`push.sh` also pushes the pod
      app's `main.py`, which restarts the app). ImageLabCore changes: `scripts/push-node.sh`.
   2. **Then commit and push to GitHub**, every repo you touched. In ImageLab, commit the rebuilt
      `dist/` together with `src/` — the image copies `dist/` and never builds it.
   3. **Then move the pin** in this repo's `Dockerfile` (and the "image pins" line below) to the
      new ImageLab / ImageLabCore commit, commit, push. That rebuilds the image, so the change
      stays in every new pod.
   Do not stop to ask "push it?". The answer is always yes.

## Credentials

`RUNPOD_API_KEY`, `CIVITAI_API_KEY`, `COMFY_LOCAL_USER`, `COMFY_LOCAL_TOKEN` live in
`~/Github/ImageLabProject/.env`, beside the three repos. See `.env.example` there. Only this
repo needs it, and only for `scripts/`.

```sh
cd ~/Github/ImageLabProject && set -a && . ./.env && set +a
```

## Starting a pod

The GPU changes with the job. What does not change: **secure cloud, US**. Community is cheaper and
not worth it — a community RTX 5090 was still pulling the 8.3 GB image fifteen minutes in at about
10 MB/s, while a secure one served in eighty seconds. First boot downloads ~159 GB of models, so the
uplink is the whole game.

List what is available and what it costs:

```sh
curl -s https://api.runpod.io/graphql -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ gpuTypes { id displayName memoryInGb lowestPrice(input:{gpuCount:1}) { uninterruptablePrice } } }"}' \
  | jq -r '.data.gpuTypes | map(select(.lowestPrice.uninterruptablePrice > 0))
           | sort_by(.lowestPrice.uninterruptablePrice) | .[]
           | "\(.lowestPrice.uninterruptablePrice)/h  \(.memoryInGb)GB  \(.displayName)"'
```

**Do not trust the per-datacentre availability query.** It only sees secure cloud and returns
nothing for GPUs that certainly exist — an A40 with High stock globally came back empty for every
US datacentre. Deploying is the only real test, and a failed deploy costs nothing.

```sh
curl -s https://api.runpod.io/graphql -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' -d "{\"query\":\"mutation { podFindAndDeployOnDemand(input: {
    cloudType: SECURE, gpuCount: 1, countryCode: \\\"US\\\",
    containerDiskInGb: 30, volumeInGb: 512, volumeMountPath: \\\"/workspace\\\",
    minVcpuCount: 4, minMemoryInGb: 16,
    gpuTypeId: \\\"NVIDIA GeForce RTX 5090\\\",
    name: \\\"imagelab\\\", imageName: \\\"ghcr.io/angelmankel/imagelab-pod:latest\\\",
    ports: \\\"8188/tcp\\\",
    env: [{ key: \\\"CIVITAI_API_KEY\\\", value: \\\"$CIVITAI_API_KEY\\\" },
          { key: \\\"COMFY_AUTH_USER\\\", value: \\\"$COMFY_LOCAL_USER\\\" },
          { key: \\\"COMFY_AUTH_TOKEN\\\", value: \\\"$COMFY_LOCAL_TOKEN\\\" }]
  }) { id costPerHr machine { gpuDisplayName location } } }\"}" | jq -c .
```

- `volumeInGb: 512` is a **pod-local** volume (models.txt alone is ~159 GB since Wan joined it; the template has 512 too, since 09-29): made with the pod, gone with it, no standing
  storage bill, and it survives a *stop*. A network volume bills between sessions.
- **Never pass `volumeInGb` for a B200 or B300.** Blackwell datacentre nodes have no local disk and
  every attempt returns "no instances available" until it is dropped. An RTX 5090 is Blackwell too
  but takes a volume fine.
- **Without a volume, `/workspace` is the container disk**, so a B200/B300 needs
  `containerDiskInGb: 250` or the ~159 GB of models do not fit. Deploying the template on a B200
  silently drops its volume and leaves 30 GB: raise the container disk (Edit Pod, or `podEditJob`).
- `COMFY_AUTH_USER` / `COMFY_AUTH_TOKEN` must be `COMFY_LOCAL_USER` / `COMFY_LOCAL_TOKEN` so the saved
  Traefik login keeps working. The image defaults the user to `imagelab`.
- `COMFY_AUTH_ALIASES` (optional, space-separated) adds more user names with the same password, for
  a browser that still sends an older one. Add `{ key: \\\"COMFY_AUTH_ALIASES\\\", value: \\\"name\\\" }` to `env`.

**Or from the RunPod console:** the private template **ImageLab Pod** (`63ya3ikzof`) has the image,
disks, port and env already set, including the secrets. Pick Secure Cloud and a US GPU. If
`.env` credentials change, update the template too: it holds its own copy.

Read the address once it is actually serving:

```sh
curl -s https://api.runpod.io/graphql -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ pod(input:{podId:\"POD_ID\"}) { runtime { uptimeInSeconds ports { ip publicPort type } } } }"}' \
  | jq -r '.data.pod.runtime.ports[]? | select(.type=="tcp") | "\(.ip):\(.publicPort)"'
```

`runtime: null` means it is still pulling. **Read the port again after it answers** — a read
straight after a resume can return the previous port, which has already sent Donny to repoint
Traefik at a dead address once.

Give him the `ip:port`. He fronts it with Traefik on his own domain and
repoints by hand, because **the port changes on every resume**. A 502 on the domain while the
direct `ip:port` answers 200 means that and nothing else.

## What a pod serves

| | |
|---|---|
| `/` | ComfyUI |
| `/imagelab/` | **ImageLab**, served by nginx off the volume |
| `/imagelab/api/*` | ImageLabCore: `hashes`, `downloads`, `models`, `favorites`, `preview-size`, `version` |
| `/pod/app/api/files`, `/pod/app/api/node` | PUT only: what `push.sh` and `push-node.sh` write through |
| `/llm/` | the pod's own Ollama (local LLM for ImageLab's AI helpers). `start.sh` installs it onto the volume (`/workspace/ollama`, ~1.4 GB, once per `OLLAMA_VERSION`) and runs it on 127.0.0.1:11434; models stay on the volume. `SKIP_LLM=1` turns it off. Context capped at 16384 (`OLLAMA_CONTEXT_LENGTH`). Log: `/pod/logs/llm.log` |
| `/video-comfy/` | a **second ComfyUI, for video**, on 127.0.0.1:8191 (`COMFY_VIDEO_PORT`). nginx strips the prefix; websockets, basic auth and proxy settings as for `/`. On by default with 2+ GPUs (it gets its own card) or one GPU of ≥ 80 GB (shared); `COMFY_VIDEO=1/0` forces it. 502 when it is off or still starting. See *The second ComfyUI* below. Log: `/pod/logs/comfy-video.log` |
| `/video-comfy/imagelab/api/*` | goes to the **first** ComfyUI (one owner for the hash index and downloads), except `/video-comfy/imagelab/api/favorites*`, which the second serves itself (a favorite is copied out of *its* temp/) |
| `/pod/logs/instances.json` | what `start.sh` launched at boot (configuration, not liveness), e.g. `{"instances": 2, "gpus": 2, "mode": "separate", "image": {"path": "/", "gpu": 0, "vram_gb": null}, "video": {"path": "/video-comfy/", "gpu": 1, "vram_gb": null}, "llm": {"path": "/llm/", "gpu": 0}}`. `mode` is `single` (one ComfyUI), `shared` (two on one card; `vram_gb` = each one's share) or `separate`; `video` / `llm` are `null` when off; `gpu` is an nvidia-smi index, `null` when unknown |
| `/pod/logs/download.log` | model download progress |
| `/pod/logs/models-complete` | 200 once every model has landed |

Behind nginx basic auth: user `COMFY_LOCAL_USER` (`imagelab`), password `COMFY_LOCAL_TOKEN`.
ImageLab calls only ComfyUI and `/imagelab/api/*`, never `/pod/app`, so the pod routes can change
without an ImageLab build. Models are installed from ImageLab's model browser, which goes through
`/imagelab/api/downloads`.

First boot fetches **~159 GB** from `models.txt` (Wan video is ~73 GB of it). Civitai answers 403 to some
aria2 requests — normal, the curl fallback picks them up. Watch `models-complete`.

## The second ComfyUI (video)

A Wan render holds a ComfyUI for minutes and its queue is one line, so `start.sh` runs a second one
for video and ImageLab treats it as a second server whose host carries the path
(`<pod>/video-comfy`); which GPU it gets is below. It starts once the first answers
`/system_stats` (staggered: both import every custom node, and several packs write their config
files then), runs in a restart loop, and logs to `/pod/logs/comfy-video.log`. Same `/opt/ComfyUI`, so models, input, output, custom nodes,
ImageLabCore and the user dir (saved workflows, settings) are shared. Its own flags:

| | why |
|---|---|
| `--temp-directory /opt/comfy-video` | its temp is `/opt/comfy-video/temp` (ComfyUI appends `temp`). ComfyUI wipes temp at every start, and ImageLab saves through PreviewImage — a restart of one must not eat the other's images |
| `--database-url sqlite:///:memory:` | ComfyUI takes a file lock on `user/comfyui.db` for one process (`app/database/db.py` `_acquire_file_lock`); the DB only holds the assets index, which is off |
| `IMAGELAB_CORE_SECONDARY=1` | ImageLabCore (≥ `3e51a5d`) skips its hash scan, checkpoint sort and startup downloads and serves only favorites + version; `/imagelab/api/version` says `"secondary"`. `IMAGELAB_AUTO_DOWNLOAD` is blanked too, for an older copy on the volume |
| `--reserve-vram <images' share + 4>` | only when both share one card; see VRAM below. The first ComfyUI then gets `--reserve-vram <video's share + 4>` |

`COMFY_VIDEO_ARGS` adds flags to it, as `COMFY_ARGS` does to the first.

**GPU layout.** `start.sh` counts the GPUs (`nvidia-smi --query-gpu=index,uuid,memory.total`) and logs
one line, e.g. `[start] 2 GPU(s): image→0, video→1, llm→0`:

| GPUs | image ComfyUI | video ComfyUI | Ollama |
|---|---|---|---|
| 2+ | GPU 0, whole card | GPU 1, whole card, always on, no VRAM flags | GPU 2 if there is one, else GPU 0 |
| 1, ≥ 80 GB | GPU 0, `--reserve-vram` | same card, `--reserve-vram` (split below) | shares |
| 1, < 80 GB (5090) | GPU 0 | off | shares |
| none seen | unpinned | off | unpinned |

Ollama goes with images, not video: its calls are short and come while prompts are written, and
video is the long job that wants a whole card; left to spread, Ollama puts layers on every GPU as
soon as a model does not fit one. Overrides: `COMFY_VIDEO=1/0`; `COMFY_IMAGE_GPU`,
`COMFY_VIDEO_GPU`, `LLM_GPU` (nvidia-smi indexes; one that does not exist is logged and ignored).
Image and video on the same index means shared mode, VRAM split and all.

Each process is pinned by `CUDA_VISIBLE_DEVICES=<GPU UUID>` in its environment, with
`CUDA_DEVICE_ORDER=PCI_BUS_ID`. Not `--cuda-device`: the pinned `main.py` sets the variable from it
only after `comfy_aimdo` has loaded, and an environment survives `/manager/reboot`'s `execv` as argv
does. A UUID because CUDA numbers devices fastest-first by default, nvidia-smi by PCI bus.

To get two cards, deploy with `gpuCount: 2`. **Resume with the same `gpuCount`**: the
`podResume` below says 1, and a two-GPU pod resumed that way comes back in one-card mode.

**VRAM on a shared card.** ComfyUI assumes it owns the GPU. The pinned v0.34.5 runs *dynamic
VRAM* (comfy-aimdo 0.4.15) by default on NVIDIA with torch 2.8; there is no `--normalvram` in this version. Under
it, `--reserve-vram` caps a process's own allocations at total − reserve (aimdo `budget_deficit`,
`simple_vram_headroom`), and a process that runs short evicts its *own* weights, which then stream
from RAM: it never takes memory back from the other, and an idle ComfyUI keeps its weights
resident. So each one reserves the other's share. Split: video 55% of (total − 4 GB), images the
rest; the 4 GB is what aimdo does not count (two CUDA contexts, onnxruntime in the RMBG/WD14 nodes).

| GPU | images cap | video cap |
|---|---|---|
| A100 / H100 80 GB | ~35 GB | 41 GB |
| H200 141 GB | ~61 GB | 75 GB |
| B200 180 GB | ~79 GB | 96 GB |

`COMFY_VIDEO_VRAM_GB` moves the split; a `--reserve-vram` in `COMFY_ARGS` / `COMFY_VIDEO_ARGS` wins
over it (argparse keeps the last). Not used, and why: `--vram-headroom` also keeps that much free
*device-wide*, so the second process to grow would starve; `--highvram` / `--gpu-only` turn dynamic
VRAM off; `--disable-smart-memory` frees nothing when idle (models stay until the next load) and
makes every load unload the rest.

Caveats, none of them tried on a pod yet:
- **GGUF** loads through ComfyUI-GGUF's own `ModelPatcher`, not the dynamic one, so it takes the old
  estimate path, where the reserve is subtracted from the device's free memory *on top of* what the
  other process already holds. With the other instance busy, a GGUF model may load mostly
  offloaded (slow, not broken). Safetensors Wan (models.txt) is unaffected.
- Ollama's VRAM is not part of the split. On a shared card it loads beside both; ComfyUI's dynamic
  VRAM checks the device's real free memory and gives way by streaming its own weights.
- Both share **system RAM**; each sizes its RAM cache and pinned buffers as if it were alone.
- `SaveImage` / `SaveVideo` counters scan `output/` per save: two saves with the same prefix in
  the same instant could pick the same number. PreviewImage names carry a random part.
- `scripts/push-node.sh` restarts the second too, after the first is back; `scripts/pull-images.sh`
  also reads `/video-comfy/history`. Both skip it when `/video-comfy/system_stats` is not 200.
- The ComfyUI editor at `/video-comfy/` should work: frontend 1.49.6 loads `./assets/…` and takes its
  API base from `location.pathname`. nginx cuts the prefix from the raw request line (a `map` on
  `$request_uri`), so an encoded `%2F` in `/api/userdata/workflows%2F…` survives.

## Changing code on a running pod

Neither needs an image rebuild.

```sh
cd ../ImageLab && npm run build && cd -
scripts/push.sh      <ip:port>    # ImageLab dist/ + the pod app   (~instant)
scripts/push-node.sh <ip:port>    # ImageLabCore + ComfyUI restart, both ComfyUIs (~15s each)
```

Both work because that code lives on the pod's **volume**, symlinked into place by `start.sh`.
`push-node.sh` also POSTs `/manager/reboot`, which ends in `os.execv` — ComfyUI re-execs in place,
so the PID survives, the container does not restart and the port does not change. Because it is a
real restart, adding a route is no different from changing one.

**After resuming onto a new image, push both anyway.** The volume copy is seeded from the image
only when it is absent, so an older copy keeps running and the image's version never appears. It
is deliberate — it stops a rebuild wiping live edits — and it surprises everyone once.

A rebuild is only needed for `start.sh`, `nginx.conf.template`, the `Dockerfile`, a new custom
node, a new Python dependency, or to move the pinned ImageLab/ImageLabCore commits.

## Workflows

ComfyUI saved workflows are kept in `workflows/` in this repo, one `.json` per workflow (subfolders
allowed). That is the copy that survives a terminate.

```sh
scripts/workflows.sh pull <ip:port>   # pod -> workflows/, then commit
scripts/workflows.sh push <ip:port>   # workflows/ -> pod, overwrites same-named files
```

The image carries `workflows/` and `start.sh` copies it onto a new pod at boot, only where a file
is missing. ComfyUI's user dir is on the volume, so a stop keeps workflows too. A workflow edit
does not trigger an image build (`workflows/` is not in the build's `paths:`), so `push` is how an
edit reaches a running pod, and the next image build picks it up.

Before saving a workflow, check every node and widget against `/object_info` and run it once
through `/prompt`.

**Reference workflows** for models that are not in `models.txt` yet — Wan 2.2 T2V / I2V (A14B),
Flux Dev, Z-Image Turbo, Qwen Image — are written by `scripts/reference-workflows.mjs <ip:port>`
from API graphs, through ImageLab's own converter (`workflowGraph.ts`). It checks each file round
trips and that `/prompt` refuses it only for the missing model files; each file's note lists the
files and where to get them. They have not rendered yet. Wan saves an animated WebP: SaveVideo's
format/codec are a `COMFY_DYNAMICCOMBO_V3` input that ImageLab's converter cannot read yet.

**GGUF models** (quantized, e.g. CivitAI Wan mixes) load through ComfyUI-GGUF's `UnetLoaderGGUF` (pinned in the
Dockerfile). ImageLabCore saves them as `.gguf` in `diffusion_models`; ImageLab picks the loader by extension.

**Video add-ons (2026-10-18).** ImageLab's Video mode wires these as optional steps, all off by default, and
none needed a new custom node: ComfyUI v0.34.5 already carries RIFE / FILM frame interpolation
(`FrameInterpolationModelLoader` + `FrameInterpolate`, weights in `models/frame_interpolation`, PR 13258),
`CFGZeroStar`, `EasyCache`, `TorchCompileModel`, `WanContextWindowsManual` and `WanFirstLastFrameToVideo`;
the pinned KJNodes has `WanVideoNAG` (a negative prompt that works at CFG 1) and `ColorMatchV2`. `models.txt`
got the four Comfy-Org RIFE/FILM files (~137 MB), the Anime Style v2 Wan 2.2 LoRA pairs (4 × 153 MB) and
the newer lightx2v I2V 260412 / T2V Seko V2.0 speed LoRAs (~3.7 GB). Not added, on purpose: SageAttention
(no cp311 / sm_100 wheel for torch 2.8 cu128 — a source build in the image), SeedVR2 (6.8 GB model, Python 3.12+
tested only), Fun Camera / VACE 2.2 experts (15–17 GB each), GIMM-VFI (needs cupy). None of the new graph
steps has run on a pod yet; the first run of each is the test.

**MiniMax H3 (2026-10-19).** ImageLab's Video mode has a Wan 2.2 | MiniMax H3 switch. H3 is one 33B omni model (video +
32 kHz stereo audio, 24 fps, 5–15 s; text, first/last frame, reference pictures). Its nodes are in ComfyUI v0.34.5 itself
(`comfy_extras/nodes_minimax_h3.py`: `EmptyMiniMaxH3LatentAV`, `MiniMaxH3ImageToVideo`, `MiniMaxH3ReferenceToVideo`,
`MiniMaxH3AddGuide`, `MiniMaxH3SigmaShift`; `CLIPLoader` type `minimax`) and the pinned KJNodes (`MiniMaxLowVRAMAttention`,
`MiniMaxChunkFeedForward`); the pod's ComfyUI also ships the `video_minimax_h3_*` templates. `models.txt` got the templates'
files (~69 GB): pruned INT8 fl2va + ref2va (21 GB each), the NVFP4-AWQ Qwen3-VL-32B text encoder (16 GB; the model card says it
needs no Blackwell GPU — unverified on the A100), fp16 video VAE, fp32 audio VAE, three lightx2v turbo LoRAs. Pod
`kvcm8mscs0ffw3` also has the INT8 text encoder (27 GB) as a fallback, not in models.txt. The full pruned bf16 (40 GB) does not
fit the shared card's 41 GB video share. Not added: SageAttention (no wheel; artefacts with int8_convrot), the hosted 2K
upscaler / Context-IR (Comfy Cloud only), Fun ControlNet. **No H3 clip has been rendered from ImageLab yet** (Donny asked for
no test renders); the graphs were validated against `/object_info` and `/prompt`. Licence: MiniMax community licence, and
Comfy's page says use in the US / EU / UK / Korea needs a commercial licence — Donny was told on 10-19 and asked for it anyway.

Anima is a diffusion model only: `UNETLoader` from `diffusion_models`, with
`CLIPLoader` (`qwen_3_06b_base`, type `stable_diffusion`) and `VAELoader` (`qwen_image_vae`).

## Stopping, resuming, terminating

```sh
# stop — keeps the volume and the models, no GPU billing
-d '{"query":"mutation { podStop(input:{podId:\"POD_ID\"}) { desiredStatus } }"}'
# resume — re-pulls :latest, models already there, NEW PORT
-d '{"query":"mutation { podResume(input:{podId:\"POD_ID\", gpuCount:1}) { desiredStatus } }"}'
# terminate — the volume and everything on it is gone, for good
-d '{"query":"mutation { podTerminate(input:{podId:\"POD_ID\"}) }"}'
```

Stop/resume is how you pick up a new image. **Pull images and push repos before either.**

## Where this stands (2026-09-22)

- **No pod is running.** `ydq68v43bc6z23` (H200, US-NC-1, $5.29/h, started by Donny) was terminated on 10-18 after its
  107 images/videos were pulled to `/mnt/games/images/runpod/10-18-2026/` and its 14 workflows (unchanged). It ran
  ImageLab `0170a32` + ImageLabCore `c029913` (Model Type dropdown flicker fix; download clears ComfyUI's folder cache).
- `7bvm59dppz3gxk` (B200, US-CA-2, $6.79/h, started by Donny) was terminated on 09-30 after its
  images were pulled to `/mnt/games/images/runpod/09-29-2026/` and `09-30-2026/` and its 14 workflows (unchanged).
  Wan (SmoothMix) and a GGUF Wan mix were tested on it; ComfyUI-GGUF went on live through ComfyUI-Manager.
- `9pd24b4wivsx8x` (A100 SXM, US-KS-2) was terminated on 09-29 after its 234
  images/videos were pulled to `/mnt/games/images/runpod/09-29-2026/` and its 14 workflows (unchanged). The Wan /
  Flux / Z-Image / Qwen models and helper files fetched on it are NOT in models.txt (see HANDOFF).
- Before that: `36zinlcas823hs` (A100 SXM, US-WA-1) was terminated on 09-26. On Donny's
  explicit instruction its 168 images were deleted, NOT pulled (ComfyUI restart wiped temp/,
  history cleared) — there is no local copy of that session's images.
- `69rxv7kei9cxtn` (A100 SXM, US-WA-1) was terminated on 09-24 after its
  88 images were pulled to `/mnt/games/images/runpod/09-24-2026/` and its workflows (unchanged).
  It never got ImageLabCore `329f992` pushed; the image carries it.
- `p39jg1z8q1tgff` (A100 SXM, US) was terminated on 09-23 after its
  images were pulled to `/mnt/games/images/runpod/09-23-2026/` (147 files, 18 favorites) and its
  workflows were pulled (unchanged).
- **The image pins ImageLabCore `b944459`** (batch live preview of every picture, download retry; download without a server key says so: NO_TOKEN; live preview cap 1024 by default, `IMAGELAB_PREVIEW_SIZE`, `GET/POST /imagelab/api/preview-size` changes it with no restart; secondary mode for the pod's second, video ComfyUI: `IMAGELAB_CORE_SECONDARY=1`; diffusion models sorted out of checkpoints/, 8-connection downloads, Hugging Face URLs, model inspect; GGUF files keep `.gguf` and go to diffusion_models; a finished download clears ComfyUI's folder cache so the file shows in the pickers without a restart).
- **The image pins ImageLab `8937ee9`** (Snippets: drag onto categories, select all / none, Shift-click ranges; Selected history tile ring is back; Prompt part drag fixed, wider highlight, Merge into dropdown fixed; Server popover shows the real live-preview method + fix hint; Prompt studio writes keep running when closed; Write it badge; Ingredients: + Add first, picker stays put, tile names wrap; Prompt studio focuses the idea box; dropdowns never open on focus; Clean thin scrollbars, no native arrow buttons on Windows Chrome; Starters: one toolbar row, general CivitAI feed by default, NSFW view uncovered; Small drop zones fit their box, Paste always there; Parameters, Composition and Settings sections fold with the shared Collapse; Tooltip and hint text audit: short and simple; Round floating arrows replace every side-strip pager; Input picture Edit opens the GPU Edit mode, not the old modal; Reset-to-default on every parameter; ComfyUI workflows list: A–Z by default, sort menu, search always; GPU canvas is the main stage; phone Edit page; Toasts only for critical errors; parameter changes undoable; Composition shape row: unique ratios, Portrait/Landscape switch, no wrap; Starters model search with thumbnails, faster gallery, loading states; Generate all stays in its starting session; Step progress rings, queued dashed, connectors light up when done; Edit mode on the PixiJS GPU canvas with a left tool bar; Write it prompt studio + AI Generate snippets; Slider value bubble, switch gap and inset, spinners; New Monolith logo everywhere, PWA icons, live favicon; History bar wraps, one kind switch; bigger collection tiles, wheel scroll, edge fade; Prompt tab folds use the shared Collapse; Model card rebuilt: one square picture, one strength, Recommended + Apply; Deleted images stay deleted; Snippets reinvented: quick add modal, manage categories; sticky prompt gap fixed; Shared loading components: skeleton tiles, spinner, loading image; ComfyUI jobs watch: no /queue refetch on every progress tick; Every arrow-key list auto-scrolls its highlight; ComfyUI's own prompts in the Jobs list, progress chip over the frame; Model viewer right panel re-organised with folds, Recommended settings Apply; App SVG cursor set + Themes App cursors toggle; Shared Collapse + keyboard-list auto-scroll, / snippets list scrolls; History and live previews scoped per session, Reset session, Clear history, arrow keys; Composition tab redesign: mode switch, shape chips, size sliders; History page: three columns, grid / preview / metadata; Stale step badge, fingerprints, Generate all re-runs only stale steps; Native title tooltips drawn as ours, never two at once; Home is a full-screen home page with ghost tiles; Model viewer shows all pictures, tap opens full-screen viewer; Compare view: line follows the mouse, touch toggle, no filenames; Drag prompt parts by a floating grip, Alt+arrows, snippet parts look different; UI scale fix: tooltips, popovers, menus, modals placed right at every scale; ComfyUI workflows list redesign: one-line rows, menu, search, sort; Canvas click opens the real full-screen viewer, slim auto-hiding nav; Session tabs redesign: no border, colour ring, running arc; Model modals fit every UI scale; NSFW opt-in; Prompt tab: pinned prompt box, fold to preview, one scroll, On only filter; Paste button on every picture slot; Live preview frames never flash, 150 ms cross-fade; External viewer API for model images; ComfyUI server picker by name replaces Image/Video switch; App-wide undo/redo (Ctrl+Z, top-bar buttons) + 12-hour time helper; Prompt box: periods split parts, no AVOIDING, no keyword chips, no stale bar; Embeddings: one Strength, Recommended settings label; ×N cycle moves to Settings → Generate; ComfyUI tab opens saved workflows again (no DataCloneError); Workflow steps use the prompt card, tiles, friendly labels mapping; Settings → Themes: palettes, generator, OLED, fonts, scale, motion, import/export; Settings → Hints editor, more hint ids, toast sounds; autocomplete face-lift, seed NumberField, SearchField; canvas → sends instantly; picker adds a step when none; Refine/Upscale/Remove BG job chips carry their step; Write it: cleaner, cog with system prompt + per-provider LLM params; Generate all under + Add, refuses a broken chain; job chips show the step that queued them; new full-screen viewer: rail, Send/Details panel, slideshow; top-bar Queue split into Job queue + Download queue; Refine, Upscale, Remove BG steps; Loopback leaves the Image step; shared Slider + Advanced SliderRow, NumberField, dropdown look; new Spark logo, icons; New session from tile fix; results credited to queuing step; selected-model card redesign for every model kind; Starters replaces Prompt library: masonry gallery + filters; dropping an input picture on its own zone does nothing; drop pictures on the Steps rail, more drag sources; batch results as arrays, several live previews tiled; Composition tab rebuilt, Model default size; server chip popover: every server, status, preview size; Models browser tiles, version picker, sticky wider detail panel; smart prompt box, one style/snippet tile grid, pos/neg toggle; job row on the stage, many queued runs; session tabs, Home masonry, session title, footer, F fullscreen; Collections in history: tiles, drag to move, Undo delete; step tabs Prompt / Composition / Model / Parameters; one shared input-image drop zone everywhere; Generate never Stop, xN tap-to-cycle per step; rail remove/drag/error ring/fold, step-kind picker; mute + hints toggles, UI sounds, H hotkey; canvas Remove BG button, compare split, crop, canvas menu; live tab title + favicon from one job-progress hook; workflow steps follow step 1 models, badge fix; ComfyUI tab: Generate, workflow files, hide menus, queue remembered; step I/O standard and addStepAfter; one button shape, radius token -15%, fast tooltips, hints list; shared Remove BG function (core BiRefNet); right-click menus for steps, history and model tiles; drag-and-drop layer: payload, useImageDrag/useImageDrop, Send-to sheet; no viewer/canvas animations, live preview toggle; app-wide right-click menu registry; model viewer fits + big modal (items 6, 32 viewer); remove AI provider from its Settings row, with Undo; AI providers with one active + Local; Model preview order wired, Most popular real + 7-day cache; key boxes ignored by password managers; NSFW picker reads as Max rating; Source segment in ember; preview order defaults to Most popular; Style row edge fade; snippet category edge fade; tighter Batch stepper; searchable sampler / scheduler / VAE; remove x on the model bubbles; snippet rows tidied; toasts close within 3 s; delete outputs with Undo; Off · Auto · Pick step input; Batch in the Generate bar; Source segmented + remembered; no double image results from run stores; server history real times; history 470 wide, no All chip; wheel scrolls the Style row; Negative prompt card; snippets redo with Browse all; models filter bar dropdowns; settings sidebar + search; history This step | All; viewer fit; trigger words hidden under Auto; tab icons inline; sideways rows swipe; size in the Input tab; ember logo as the app icon; model viewer scrolls over a modal; next UI installable as a PWA: manifest, icons, service worker; Wan LoRA high+low pairs in one card; scroll kept in model lists; stage video player; galleries uncensored, search hits CivitAI; one model component for all models, Recall; model tiles play clips on hover; Downloaded list shows every installed file; next Workflow step with the saved workflows; next Video step end to end; stage size + time badge, job durations; slideshow speed chips; next Image step = base + Loopback, no Passes; Loopback card; clock NN:NNAM/PM; models picker: All time + X defaults, no period on a text search; snappy fullscreen viewer + instant close, stage pinch zoom, top bar clock / keys / fullscreen, slim panel handles, model viewer preload, dead CivitAI video-still covers fixed; models modal HTTP 400 fix: no browsingLevel on /models; the next UI at /imagelab/next/ baked into the image: fullscreen model viewer, Library video autoplay, one big models modal for every picker, models before download; Settings → Workspace listed last; new workspace Phase 3: the Workflow step as chips, quick-search + phone-tab hooks; Phase 2: the Video step as chips with the motion-prompt hub; Phase 1: steps bar, full-height stage, Image step with prompt hub + chips, Settings → Workspace → Classic workspace falls back; downloads listed once per pod; browser tab progress: coloured favicon with a ring, percent in the title; video prompt tools: presets, CivitAI prompts for video models, AI video prompt, save, clear; MiniMax H3 bucket so H3 LoRAs pass the H3-only filter, video galleries shown as first-frame stills; prompts from CivitAI for the installed models, picture-search button on the Prompt box; MiniMax H3 engine in Video mode, clips with audio; tabs, quick search, My models, embeddings, browser, loopback frames; CivitAI image meta fix; Clear all button; phone Settings; phone AI generator + selects; model types + quality-tag pills + BREAK; video previews play in browser, modal and fullscreen; no wheel seek on tiles; single-pick model picker (Shift / long press for several); Anima family; SD 1.5; Flux, Z-Image Turbo, Qwen-Image families; Video view (Wan 2.2); GGUF Wan models via UnetLoaderGGUF, no second speed LoRA on mixes that have one inside; Loopback dual sliders; local LLM provider (Ollama) + model manager; send to video + pick a generation in drop zones; PWA re-checks index.html; OLED black darkness; Model Type dropdown no longer flickers in its modal; base-model family filter in the model downloader and My models; phone Parameters settings list with swipe-back; Venice model dropdown, AI picker flicker fix; local LLM on Home PC or This pod; Video view in labelled sections, phone settings list; unified Image / Video / Workflow workspace with Simple / Advanced, snippet chips, video server roles; app-wide dropdown placement fix; video parameters, presets, sweeps, NAG, RIFE interpolation, end image, colour match; game controllers incl. Switch pads; native-feeling result swiping with springs, pull-down close, shared-element open; send results between Image, Video and Workflow; low / high hints under the advanced sliders).
- **The image** is `ghcr.io/angelmankel/imagelab-pod:latest`, public, built by Actions from `main`.
  It carries ImageLab and ImageLabCore at the pins in the `Dockerfile` and the files in
  `workflows/` (five tested, five reference ones not yet rendered).
- **Models:** `models.txt` is ~232 GB (10-19: +MiniMax H3, ~69 GB; 10-18: +RIFE/FILM, Anime Style v2 LoRAs, newer lightx2v LoRAs, ~4 GB). Wan 2.2 video was added 09-29 (~73 GB: SmoothMix T2V + I2V high/low, umt5, wan_2.1_vae,
  lightx2v 4-step LoRAs, 3 fast upscalers). Before that it was ~87 GB, including Anima (Turbo + Aesthetic, in
  `diffusion_models`), Pony Realism v2.2, Mature Citron IL Unstable 3.0 and the Illustrious set.
- **Workflows** (all five run; times measured on a B200): Anima Turbo (5 s), Anima Aesthetic (11 s),
  Pony Realism (8 s), Mature Citron IL, Illustrious Ultimate Upscale (49 s, 1664x2432).
- **Model previews:** the node rescans after each pass (30s delay), skips aria2 partials,
  and rehashes files when size/mtime changes. ImageLab polls hashes every 10s and retries
  metadata after 30s; cached successes expire after a day, empty galleries after 5min,
  misses after an hour. Verified all six checkpoints resolve with images on this pod.
- **Generation workspace:** ImageLab now has one collapsible left panel, inline saved prompt
  presets, ordered refinement/upscale/resize/background-removal passes, a New seed action,
  and a live sampler progress bar that clears on completion or error. Background removal uses
  BiRefNet_toonout with explicit widget defaults. A complete four-pass test rendered on the A100;
  desktop/mobile checks and the frontend regression tests passed. This update needed only a
  frontend push, with no ComfyUI restart.
- **Open, not decided:** ImageLab still ships two console-only self-tests
  (`__exerciseCanvasStorage`, `__exerciseCanvasLayers`) that are attached in production builds;
  Donny was asked whether to delete them or make them dev-only and has not said.
- **Worth knowing:** the LAN ComfyUI boxes (`comfy.dev`, `comfy2.dev`) still run an older
  ImageLabCore that answers `/imagelab/*`, not `/imagelab/api/*`, so ImageLab's model browser and
  favorites are blind against them until they are updated.
- A RunPod MCP server is configured for this project folder (`claude mcp` local scope), so a future
  session may have RunPod tools instead of the GraphQL calls in this file.

## Facts that cost time — do not relearn them

1. ComfyUI runs `steps × denoise`. "10 steps" typed literally runs two and does nothing.
2. A latent upscale destroys linework. Enlarge in PIXELS through an anime upscaler, then add
   detail. The Passes panel has a Latent/Image switch for this.
3. Setting a `negative` REPLACES a graph's baked-in negative.
4. Seeds are fixed unless set. Anatomy must lead the prompt.
5. Civitai answers 403 to HEAD and to anonymous requests; a GET with `?token=` works. Sizes come
   from `Content-Range`, never from the API's `sizeKB`.
6. A graph's `last_link_id` can be stale. Number new links from the real maximum.
7. **Verify node inputs against `/object_info` before trusting a graph — and read the whole option
   list.** A truncated read once "proved" `ImageScale` rejects `lanczos`, which it does not.
8. A custom node cannot be installed into a running pod: ComfyUI-Manager refuses arbitrary git
   URLs, aiohttp freezes its router at startup, and `custom_nodes` is in the image layer. The
   volume symlink plus `push-node.sh` is the way around all three.
9. **When Donny reports a mouse or input problem, ask whether it happens outside the app.** He
   works over Moonlight, whose absolute mouse mode strands the cursor at a screen edge;
   `Ctrl+Alt+Shift+M` fixes it and it is not a UI bug.
10. **ImageLabCore's downloader is one connection, about 1 MB/s from Civitai.** A 7 GB checkpoint is
    an hour. `download-models.sh` uses aria2 with eight connections and gets 3-7 MB/s for the same
    file, which is why `models.txt` is the place to add a model that every pod should have. For a
    one-off on a live pod, aria2 is installed: run it there rather than waiting on the API.
11. **The ComfyUI editor adds a `control_after_generate` slot to any INT named `seed`**, declared in
    `/object_info` or not (`UltimateSDUpscale` does not declare one). A saved workflow therefore has
    an extra `"randomize"` in `widgets_values` after that seed. Anything reading widgets positionally
    has to expect it or every widget after the seed is read one slot off.
13. **`SaveVideo`'s `format` is a dynamic combo (COMFY_DYNAMICCOMBO_V3).** In an API graph the chosen option's
    nested inputs travel as dotted keys: `format: "mp4"`, `format.codec: "h264"`, `format.codec.encoding:
    "re-encode"`, `format.codec.encoding.crf: 18` (`_io.py` `finalize_prefix` / `build_nested_inputs`). A nested
    input that is absent is simply not registered, so the plain `format: "mp4", codec: "h264"` pair (the hidden
    top-level `codec`) stays valid. Derived from the v0.34.5 source, not yet run.
12. **A pod's basic auth is one user.** A browser or proxy that still sends an older name gets 401 on
    every request, and the page hangs with no login box. `COMFY_AUTH_ALIASES` is the escape hatch.

## Verifying

Donny tests; do not drive his mouse. Use the offscreen harness:

```sh
node scripts/lab-check.mjs <url> [shot.png]              # loads a page, reports console + whether it rendered
node scripts/queue-workflow.mjs <ip:port> <file.json>    # runs a saved workflow the way ComfyUI would
```

Both need `npm install` once in this repo (puppeteer-core) and a local Chromium.

`queue-workflow.mjs` is the way to check a workflow. A file in `workflows/` is an **editor** graph;
`/prompt` wants an **API** graph. Rather than convert it by hand, the script loads the file into the
pod's own ComfyUI frontend offscreen, lets `app.graphToPrompt()` convert it, posts that, and waits
for the result. What it catches is what a person pressing Queue would hit.

Check node inputs against `/object_info` before writing a graph. Renders are cheap; a wrong graph
that looks right is not.
