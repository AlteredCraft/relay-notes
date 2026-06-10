#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy",
#   "safetensors",
# ]
# ///
"""Convert Whisper MLX assets from .npz to .safetensors.

Background: mlx-swift's `loadArrays(url:)` reads safetensors only — not npz —
even though Python `mlx.load(...)` handles both. The HF model repo
`mlx-community/whisper-tiny.en-mlx` ships `weights.npz`, and the
`ml-explore/mlx-examples/whisper/mlx_whisper/assets/mel_filters.npz` ships
the precomputed mel filterbank. Both need converting once.

Usage:
    scripts/convert-whisper-assets.py <input.npz> <output.safetensors>

The script preserves the dict keys (e.g. `mel_80` / `mel_128` for the mel
filterbank file; the per-layer Whisper weight names for `weights.npz`).
"""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path

import numpy as np
from safetensors.numpy import save_file


def load_npz(path: Path) -> dict[str, np.ndarray]:
    """Read an .npz file (compressed or not) into a flat dict of numpy arrays."""
    if not zipfile.is_zipfile(path):
        sys.exit(f"error: {path} is not a valid .npz archive")
    with np.load(path) as data:
        return {key: np.asarray(data[key]) for key in data.files}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="input .npz file")
    parser.add_argument("output", type=Path, help="output .safetensors file")
    args = parser.parse_args()

    arrays = load_npz(args.input)
    if not arrays:
        sys.exit(f"error: {args.input} contains no arrays")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    save_file(arrays, str(args.output))

    summary = ", ".join(f"{k}{list(v.shape)}" for k, v in arrays.items())
    print(f"wrote {args.output} ({len(arrays)} arrays: {summary})")


if __name__ == "__main__":
    main()
