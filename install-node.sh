#!/usr/bin/env bash
# install-node <git url> <commit> <dir name>
# Clones a custom node pack at a pinned commit and installs its requirements.
# Falls back to per-line installs (with --no-build-isolation) so one optional dep
# cannot fail the whole image; the node classes we need are verified at runtime.
set -euo pipefail
url=$1; commit=$2; name=$3
dest=/opt/ComfyUI/custom_nodes/$name
git clone "$url" "$dest"
git -C "$dest" checkout --quiet "$commit"
git -C "$dest" submodule update --init --recursive
rm -rf "$dest/.git"
req=$dest/requirements.txt
if [ -f "$req" ]; then
  if ! pip install -r "$req"; then
    echo "[install-node] bulk install failed for $name, retrying line by line"
    grep -vE '^\s*(#|$)' "$req" | while read -r line; do
      pip install "$line" \
        || pip install --no-build-isolation "$line" \
        || echo "[install-node] WARNING: could not install '$line' for $name"
    done
  fi
fi
if [ -f "$dest/install.py" ]; then
  python "$dest/install.py" || echo "[install-node] WARNING: install.py failed for $name"
fi
echo "[install-node] $name @ $commit installed"
