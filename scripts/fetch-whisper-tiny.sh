#!/usr/bin/env bash
# Fetch + convert the Whisper-tiny-en weights from Hugging Face into the app bundle's
# Resources directory. weights.npz is ~75 MB and is gitignored — every clone needs
# this script run once before a Debug build that exercises Whisper inference.
#
# T1.2 will replace this whole pattern with an in-app URLSession download into
# Application Support. For T1.1b the file lives inside the bundle so a tap of
# the smoke button "just works" without first-run downloads.
#
# Usage: scripts/fetch-whisper-tiny.sh
#
# Requires: curl, uv (https://docs.astral.sh/uv/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_DIR="$REPO_ROOT/Relay Notes/Relay Notes/Resources/whisper-tiny.en"
NPZ_URL="https://huggingface.co/mlx-community/whisper-tiny.en-mlx/resolve/main/weights.npz"
NPZ_PATH="$DEST_DIR/weights.npz"
ST_PATH="$DEST_DIR/weights.safetensors"

UV_BIN="${UV_BIN:-$(command -v uv || true)}"
if [[ -z "$UV_BIN" ]] && [[ -x "$HOME/.local/bin/uv" ]]; then
    UV_BIN="$HOME/.local/bin/uv"
fi
if [[ -z "$UV_BIN" ]]; then
    echo "error: uv is required (https://docs.astral.sh/uv/) and was not found on PATH or at ~/.local/bin/uv" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

if [[ -f "$ST_PATH" ]]; then
    echo "weights.safetensors already present at $ST_PATH — skipping."
    exit 0
fi

if [[ ! -f "$NPZ_PATH" ]]; then
    echo "downloading $NPZ_URL → $NPZ_PATH (~75 MB)"
    curl -fL --progress-bar -o "$NPZ_PATH" "$NPZ_URL"
fi

echo "converting weights.npz → weights.safetensors"
"$UV_BIN" run --script "$SCRIPT_DIR/convert-whisper-assets.py" "$NPZ_PATH" "$ST_PATH"

echo "removing intermediate weights.npz"
rm -f "$NPZ_PATH"

echo "done."
