# Agent instructions — ImageLabDocker

**Read `CLAUDE.md` in this repo first, in full.** It is the entry point for all three repos
(ImageLabDocker, ImageLabCore, ImageLab) and holds the rules, the pod commands, the route table,
the facts that cost time, and where the project stands today. This file only repeats what must not
be missed.

## Non-negotiable

1. **Ask before spending GPU.** A pod bills whether or not it renders (~$1/h for an RTX 5090,
   ~$6.80/h for a B200). Say the hourly rate when proposing one; terminate it when the work is done.
2. **Before terminating or stopping a pod:** `scripts/pull-images.sh <ip:port>` and
   `scripts/workflows.sh pull <ip:port>`, then commit. A terminate is final and nothing on a pod is
   backed up. A B200 has no volume, so a *stop* loses everything too.
3. **Donny tests, you do not drive his mouse.** Verify with `scripts/lab-check.mjs` (a page loads and
   renders) and `scripts/queue-workflow.mjs` (a workflow actually runs).
4. **Commit straight to `main`, no branches**, in all three repos, and push before a pod goes away.
5. **Treat these repos as brand new.** Nothing may mention where they came from (an older `ygo-*`
   repo, a Gitea copy, a "v1"). That was cleaned out deliberately.

## Layout and credentials

Three repos side by side in `~/Github/ImageLabProject/`, with one `.env` beside them holding
`RUNPOD_API_KEY`, `CIVITAI_API_KEY`, `COMFY_LOCAL_USER`, `COMFY_LOCAL_TOKEN`. Only this repo's
`scripts/` read it. Never print or commit those values.

```sh
cd ~/Github/ImageLabProject && set -a && . ./.env && set +a
```

## What is where

| | |
|---|---|
| `Dockerfile`, `start.sh`, `nginx.conf.template`, `live.py`, `app/` | the image; a change here needs a rebuild (~10 min via Actions) |
| `models.txt` | every model a pod downloads on first boot (~87 GB) |
| `workflows/` | ComfyUI workflows, seeded onto each pod at boot |
| `scripts/` | drive a pod: push code, pull images, sync workflows, verify |

`scripts/push.sh` and `scripts/push-node.sh` change a **running** pod with no rebuild. Use them
while iterating; a rebuild is only for the image files above, a new custom node, a new Python
dependency, or to move the ImageLab / ImageLabCore pins.

## Style

Match the prose in `CLAUDE.md` and the comments in the code: short, plain, and about *why*.
Comments explain the trap, never restate the line below them.
