# ImageLabDocker

The pod image. ComfyUI with every custom node pinned to a commit, a 62 GB model manifest fetched
on first boot, a small file API for updating code on a live pod, and the scripts that start, update and tear
down a RunPod box.

Pushing to `main` builds `ghcr.io/angelmankel/imagelab-pod:latest` through GitHub Actions.

Part of a three-repo project — see **CLAUDE.md**, which is the entry point for all of it:

| | |
|---|---|
| **ImageLabDocker** | this repo |
| [ImageLabCore](https://github.com/angelmankel/ImageLabCore) | the ComfyUI custom node |
| [ImageLab](https://github.com/angelmankel/ImageLab) | the web front end |

## Scripts

```sh
scripts/push.sh       <ip:port>   # ImageLab + pod app onto a running pod, no rebuild
scripts/push-node.sh  <ip:port>   # ImageLabCore + in-place ComfyUI restart, ~15s
scripts/pull-images.sh <ip:port>  # every generation -> /mnt/games/images/runpod/MM-DD-YYYY/
scripts/lab-check.mjs <url>       # load a page offscreen, report console + render
```
