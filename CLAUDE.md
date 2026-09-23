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
10 MB/s, while a secure one served in eighty seconds. First boot downloads 62 GB of models, so the
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
    containerDiskInGb: 30, volumeInGb: 100, volumeMountPath: \\\"/workspace\\\",
    minVcpuCount: 4, minMemoryInGb: 16,
    gpuTypeId: \\\"NVIDIA GeForce RTX 5090\\\",
    name: \\\"imagelab\\\", imageName: \\\"ghcr.io/angelmankel/imagelab-pod:latest\\\",
    ports: \\\"8188/tcp\\\",
    env: [{ key: \\\"CIVITAI_API_KEY\\\", value: \\\"$CIVITAI_API_KEY\\\" },
          { key: \\\"COMFY_AUTH_USER\\\", value: \\\"$COMFY_LOCAL_USER\\\" },
          { key: \\\"COMFY_AUTH_TOKEN\\\", value: \\\"$COMFY_LOCAL_TOKEN\\\" }]
  }) { id costPerHr machine { gpuDisplayName location } } }\"}" | jq -c .
```

- `volumeInGb: 100` is a **pod-local** volume: made with the pod, gone with it, no standing
  storage bill, and it survives a *stop*. A network volume bills between sessions.
- **Never pass `volumeInGb` for a B200 or B300.** Blackwell datacentre nodes have no local disk and
  every attempt returns "no instances available" until it is dropped. An RTX 5090 is Blackwell too
  but takes a volume fine.
- **Without a volume, `/workspace` is the container disk**, so a B200/B300 needs
  `containerDiskInGb: 150` or the ~87 GB of models do not fit. Deploying the template on a B200
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
| `/imagelab/api/*` | ImageLabCore: `hashes`, `downloads`, `models`, `favorites`, `version` |
| `/pod/app/api/files`, `/pod/app/api/node` | PUT only: what `push.sh` and `push-node.sh` write through |
| `/pod/logs/download.log` | model download progress |
| `/pod/logs/models-complete` | 200 once every model has landed |

Behind nginx basic auth: user `COMFY_LOCAL_USER` (`imagelab`), password `COMFY_LOCAL_TOKEN`.
ImageLab calls only ComfyUI and `/imagelab/api/*`, never `/pod/app`, so the pod routes can change
without an ImageLab build. Models are installed from ImageLab's model browser, which goes through
`/imagelab/api/downloads`.

First boot fetches **62.2 GB across 88 files** from `models.txt`. Civitai answers 403 to some
aria2 requests — normal, the curl fallback picks them up. Watch `models-complete`.

## Changing code on a running pod

Neither needs an image rebuild.

```sh
cd ../ImageLab && npm run build && cd -
scripts/push.sh      <ip:port>    # ImageLab dist/ + the pod app   (~instant)
scripts/push-node.sh <ip:port>    # ImageLabCore + ComfyUI restart (~15s)
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
through `/prompt`. Anima is a diffusion model only: `UNETLoader` from `diffusion_models`, with
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

- **No pod is running.** RunPod spend is zero. The last images pulled are in
  `/mnt/games/images/runpod/09-21-2026/` (33 files).
- **The image** is `ghcr.io/angelmankel/imagelab-pod:latest`, public, built by Actions from `main`.
  It carries ImageLab and ImageLabCore at the pins in the `Dockerfile` and the five files in
  `workflows/`.
- **Models:** `models.txt` is 88 files / ~87 GB, including Anima (Turbo + Aesthetic, in
  `diffusion_models`), Pony Realism v2.2, Mature Citron IL Unstable 3.0 and the Illustrious set.
- **Workflows** (all five run; times measured on a B200): Anima Turbo (5 s), Anima Aesthetic (11 s),
  Pony Realism (8 s), Mature Citron IL, Illustrious Ultimate Upscale (49 s, 1664x2432).
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
