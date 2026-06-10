#!/usr/bin/env bash
# Fetch + convert Whisper-en model weights (and config) from Hugging Face into
# the app bundle's Resources directory. Default is `small.en` (~250 MB download,
# ~480 MB safetensors) — empirically validated to load and run on the iPhone 15
# Pro Max within the default iOS jetsam budget (no increased-memory-limit
# entitlement needed; see CHANGE_LOG 2026-06-10).
#
# Pass `tiny.en` as the first arg to fetch the smaller (~75 MB) variant
# instead — useful as a low-friction fallback or for memory-constrained devices.
#
# Both `weights.safetensors` and `config.json` are written into
# `Relay Notes/Resources/whisper-small.en/` (the bundled resource dir is
# named after the *default* model; the actual contents follow whichever variant
# you fetched). `weights.safetensors` is gitignored; `config.json` is committed
# and matches the *default* variant — re-running this script with a different
# variant will overwrite both. The flat-bundling rule in CLAUDE.md means the
# subdirectory name is documentation, not code-load-bearing.
#
# T1.2 will replace this whole pattern with an in-app URLSession download
# manager into Application Support. For T1.1b/T1.2 dev work, the file lives
# inside the bundle so the smoke button "just works" without first-run downloads.
#
# Usage: scripts/fetch-whisper-model.sh [tiny.en|small.en]
#
# Requires: curl, uv (https://docs.astral.sh/uv/).

set -euo pipefail

VARIANT="${1:-small.en}"
case "$VARIANT" in
    tiny.en|small.en) ;;
    *)
        echo "error: unknown variant '$VARIANT' (expected 'tiny.en' or 'small.en')" >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_DIR="$REPO_ROOT/Relay Notes/Relay Notes/Resources/whisper-small.en"
HF_REPO="mlx-community/whisper-${VARIANT}-mlx"
NPZ_URL="https://huggingface.co/${HF_REPO}/resolve/main/weights.npz"
CONFIG_URL="https://huggingface.co/${HF_REPO}/resolve/main/config.json"
NPZ_PATH="$DEST_DIR/weights.npz"
ST_PATH="$DEST_DIR/weights.safetensors"
CONFIG_PATH="$DEST_DIR/config.json"

UV_BIN="${UV_BIN:-$(command -v uv || true)}"
if [[ -z "$UV_BIN" ]] && [[ -x "$HOME/.local/bin/uv" ]]; then
    UV_BIN="$HOME/.local/bin/uv"
fi
if [[ -z "$UV_BIN" ]]; then
    echo "error: uv is required (https://docs.astral.sh/uv/) and was not found on PATH or at ~/.local/bin/uv" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

echo "fetching whisper-${VARIANT} into $DEST_DIR"
curl -fsSL -o "$CONFIG_PATH" "$CONFIG_URL"

if [[ -f "$ST_PATH" ]]; then
    echo "weights.safetensors already present at $ST_PATH — skipping download (delete to re-fetch)."
    exit 0
fi

if [[ ! -f "$NPZ_PATH" ]]; then
    echo "downloading $NPZ_URL"
    curl -fL --progress-bar -o "$NPZ_PATH" "$NPZ_URL"
fi

echo "converting weights.npz → weights.safetensors"
"$UV_BIN" run --script "$SCRIPT_DIR/convert-whisper-assets.py" "$NPZ_PATH" "$ST_PATH"

echo "removing intermediate weights.npz"
rm -f "$NPZ_PATH"

echo "done."
