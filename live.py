#!/usr/bin/env python3
"""Run /workspace/imagelab-app/main.py, and restart it the moment any file under it changes.

The app lives on the VOLUME, not in the image, because an image rebuild is a ten minute round trip and a pod
restart, and that is a hopeless way to write a web page. Only this supervisor and the nginx route are baked.
If the volume has no app yet (a fresh pod), the copy shipped in the image is seeded into it once, and from then
on the volume's copy is the truth — a later image never overwrites your edits.
"""
import os, shutil, signal, subprocess, sys, time
from pathlib import Path

LIVE = Path(os.environ.get("IMAGELAB_APP_DIR", "/workspace/imagelab-app"))
SEED = Path(os.environ.get("IMAGELAB_APP_SEED", "/opt/imagelab/app"))
PORT = os.environ.get("IMAGELAB_APP_PORT", "8190")

def seed() -> None:
    if LIVE.exists() and any(LIVE.iterdir()):
        return
    LIVE.mkdir(parents=True, exist_ok=True)
    for item in SEED.iterdir():
        (shutil.copytree if item.is_dir() else shutil.copy2)(item, LIVE / item.name)
    print(f"[live] seeded {LIVE} from the image", flush=True)

def stamp() -> float:
    """Newest mtime under the app dir. Cheap enough to poll, and it needs no extra dependency."""
    newest = 0.0
    for root, dirs, files in os.walk(LIVE):
        dirs[:] = [d for d in dirs if d not in {"__pycache__", ".git", "lab", "node_modules"}]  # lab/ is static, nginx serves it
        for f in files:
            if f.endswith((".py", ".html", ".css", ".js", ".json")):
                try: newest = max(newest, os.stat(Path(root) / f).st_mtime)
                except FileNotFoundError: pass
    return newest

def spawn() -> subprocess.Popen:
    print(f"[live] starting {LIVE}/main.py on 127.0.0.1:{PORT}", flush=True)
    return subprocess.Popen([sys.executable, "main.py"], cwd=LIVE,
                            env={**os.environ, "IMAGELAB_APP_PORT": PORT, "PYTHONUNBUFFERED": "1"})

def main() -> None:
    seed()
    proc, last = spawn(), stamp()
    while True:
        time.sleep(1)
        now = stamp()
        if now != last:
            last = now
            print("[live] change detected, restarting", flush=True)
            proc.send_signal(signal.SIGTERM)
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: proc.kill()
            proc = spawn()
        elif proc.poll() is not None:
            print(f"[live] app exited ({proc.returncode}); restarting in 3s", flush=True)
            time.sleep(3)
            proc = spawn()

if __name__ == "__main__":
    main()
