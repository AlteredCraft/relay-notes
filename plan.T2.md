---
title: T2 — Second On-Device Engine (Parakeet TDT 0.6b v2 via MLX) — Implementation Plan & Handoff
date: 2026-06-13
status: living
audience: an engineer/agent continuing the Parakeet port
---

# T2 — Parakeet on-device via MLX: implementation plan & handoff

This document is a **self-contained handoff** for completing T2 (a second on-device
transcription engine: NVIDIA **Parakeet TDT 0.6b v2** via raw `mlx-swift`, behind the
existing `Transcriber` protocol). It assumes you have **not** seen the prior session.
Read §0–§4 fully before writing code; §5–§9 are the working reference.

Companion docs (read for the *why* behind the codebase):
- `CLAUDE.md` (repo root) — conventions, build/test, MLX gotchas, provider spine.
- `planning/notes.md` — the build plan; T2 is in the roadmap ("Transcription upgrades").
- `planning/transcription-tuning.md` — decisions log (T2 rows at the bottom).
- `CHANGE_LOG.md` — the two `2026-06-13` T2 entries (T2.0 decision + T2.1a).

Branch: **`t2-parakeet`** (off `t1.3-measurements`; T1.3 is not yet merged to main — fine).

---

## 0. How to work this plan

- **Stages are sequential** (T2.1b → … → T2.5) but the model port (T2.1b–e) is the bulk.
- Each stage = write Swift → `xcodebuild build` (simulator, compile-check) → for MLX
  numerics, **device-validate via `ParakeetSmoke`** (the simulator cannot run MLX).
- The **ground-truth correctness gate** is the T2.1d end-to-end substring check: the
  bundled `ls_test.flac` (LibriSpeech, ~6.7 s) must decode to a transcript containing
  *"openly shouldered the burden"* (the same fixture/assertion the Whisper `MLXSmoke` uses).
- Keep `ParakeetSmoke.swift` as the device harness; add a section per stage.
- **Commit per stage** with a `CHANGE_LOG.md` entry (repo convention — non-optional) and
  end commit messages with the `Co-Authored-By` trailer.
- Update this doc's §1 status table as you go.

---

## 1. Status snapshot

| Stage | What | State |
|---|---|---|
| **T2.0** | Model + reference decision | ✅ done |
| **T2.1a** | Config types + weight-load footprint smoke | ✅ done, device-validated 2026-06-13 |
| **T2.1b** | Mel front-end (featurizer) | ✅ done, device-validated 2026-06-13 (`[1, 667, 128]`, per-feature mean ≈ 0) |
| **T2.1c** | FastConformer encoder | ⬜ **next** |
| **T2.1d** | TDT greedy decoder + vocab decode (substring gate) | ⬜ |
| **T2.1e** | Long-audio chunking (overlap + token merge) | ⬜ |
| **T2.2** | Generalize the download store → `DownloadableModelStore(spec:)` | ⬜ |
| **T2.3** | Per-engine gating (retire the single `whisperReady` Bool) | ⬜ |
| **T2.4** | Factory: single live MLX engine (evict on switch) | ⬜ |
| **T2.5** | Wire engine end-to-end (enum/options/factory/UI/provenance/tests) | ⬜ |

**Shipped so far** (committed on `t2-parakeet`):
- `Relay Notes/Transcription/Parakeet/ParakeetConfig.swift` — `Codable` config types.
  (T2.1b: `preemph` now decodes absent→0.97; `load` marked `nonisolated`.)
- `Relay Notes/Transcription/Parakeet/ParakeetAudio.swift` — **T2.1b mel front-end**
  (`logMel` + Slaney `melFilterbank`); reuses `WhisperAudio.stft`/`hanning`.
- `Relay Notes/Transcription/Parakeet/ParakeetSmoke.swift` — DEBUG device harness (`os.Logger`);
  T2.1b added the weight-free `runFeaturizer()` section (runs first).
- `Relay NotesTests/ParakeetConfigTests.swift` — 5 config-decode tests (added explicit-null preemph).
- `Relay Notes/Views/SettingsView.swift` — "Run Parakeet smoke (console)" debug button.
- `Relay Notes/Transcription/WhisperModelStore.swift` — `DownloadCoordinator` hardened
  (300 s request timeout, `waitsForConnectivity`, made `internal`).

**Device facts established (iPhone 15 Pro Max, 2026-06-13):**
- Config parses; download intact (2357 MB on disk); `loadArrays` is **lazy** (38 MB after load).
- **617.87M params, all F32** on disk; bf16 resident floor **~1.2 GB**.
- Fits **without** the `increased-memory-limit` entitlement **iff** weights are
  cast-and-released incrementally (see §3.1).
- The 42-template weight namespace (§5.1) matches the FluidInference key mapper exactly.

---

## 2. The decision (T2.0) — what & why

**Port `mlx-community/parakeet-tdt-0.6b-v2`** (English, CC-BY-4.0, 617M params,
FastConformer encoder + TDT/RNN-T transducer decoder). Chosen over Qwen3-ASR because:
best English WER of the candidates; a **complete MIT mlx-swift reference port already
exists**; every op it needs is native in mlx-swift; weights load straight from safetensors
(no npz→safetensors conversion the Whisper port needed). Qwen3-ASR is a bigger port
surface with no Swift reference and autoregressive decode (no TDT frame-skip) — sanity-check only.

Why T2 at all (vs jumping to the LLM stages): same rationale as T1 — prove
third-party-model on-device viability (the riskiest part of the local-first thesis) on a
smaller problem than an LLM, using the same `mlx-swift` runtime L1+ will need. It also
gives an English accuracy ladder above `whisper-small.en`.

---

## 3. Load-bearing findings & constraints — READ FIRST

### 3.1 Memory: the model MUST be loaded by incremental cast-and-release

Parakeet ships **F32 only** (2.47 GB). The reference `loadParakeetModel`
(`ParakeetMLX.swift`) loads F32 into the module, then casts **all** params to bf16 and
`update()`s — holding F32 **and** bf16 at once (~3.7 GB). That **OOMs the 8 GB iPhone at
the ~3 GB no-entitlement jetsam ceiling** (observed: jetsam at 3.1 GB).

**The load path our `ParakeetMLXTranscriber` must use:** cast each tensor F32→bf16 and
release its F32 source **before** the next, with `MLX.GPU.set(cacheLimit: 0)` so freed
buffers return to the OS. This holds the resident floor at **~1.2 GB** (device-validated).
`ParakeetSmoke.run()` already implements this pattern (the `--- bf16 cast ---` loop) — copy it.
Pitfall that caused the first OOM: `var remaining = arrays` (a *dictionary copy*) left the
original `arrays` pinning all 697 F32 buffers. **Mutate the dictionary you're iterating**
(`arrays.removeValue(forKey:)`) so each F32 actually releases.

**Entitlement:** NOT needed for weights-resident. It is now gated on the **forward-pass
activation peak** (measured in T2.1c). There is ~1.8 GB headroom over the floor under the
~3 GB ceiling, so the encoder *may* fit without it — **measure in T2.1c before deciding.**
If needed, `com.apple.developer.kernel.increased-memory-limit` is L1's prerequisite anyway
and is expected to work on the free-tier sideload (per `notes.md`).

### 3.2 MLX cannot run on the iOS Simulator

Any `MLXArray` allocation or op crashes the simulator (insufficient `MTLGPUFamily`).
Therefore:
- MLX-touching **app code** is fine to *compile* on the simulator but must only *run* on device.
- MLX-touching **tests** must be gated `#if !targetEnvironment(simulator)` (they compile,
  never execute on the simulator). Non-MLX logic (config parse, pure helpers, key-map
  string transforms) should be simulator-safe and unit-tested normally.
- Numerical validation happens through `ParakeetSmoke` (DEBUG button → device → read logs).

### 3.3 Device logging must be durable (`os.Logger`, not `print`)

`print` is ephemeral to the Xcode debug session — a crash (e.g. OOM) loses it. `ParakeetSmoke`
logs via `os.Logger.notice(... privacy: .public)` (subsystem `alteredcraft.Relay-Notes`,
category `ParakeetSmoke`). Read it in the Xcode console **or** Console.app untethered
(filter the subsystem/category). Keep using this for every smoke section. Log metadata/key
dumps **before** risky materialization so they survive a crash; log progress every N
iterations so the last line localizes a crash.

### 3.4 Download robustness (the 2.5 GB file)

The weights are served via HF's **Xet CDN** (`cas-bridge.xethub.hf.co`) and large
single-stream downloads stall. The default 60 s `timeoutIntervalForRequest` aborts the whole
transfer on one stall. `DownloadCoordinator` is now hardened (300 s request timeout,
`waitsForConnectivity`). **T2.2 must additionally add:** resume from
`NSURLSessionDownloadTaskResumeData` on `-1001`/drops, a **background `URLSession`** (the
download is multi-minute and the app may background), and reuse the typed
`FailureReason`→generic-actionable-UI-message pattern (`WhisperModelSection.failureMessage`).

### 3.5 Provider-abstraction spine is load-bearing — preserve it

Every engine sits behind `Transcriber` / `TranscriptionSession`. Adding an engine = an enum
arm + an options arm + a factory arm + a settings bundle + a Settings section + a provenance
label. Do **not** special-case Parakeet outside this shape. (Details in §6.)

---

## 4. Reference materials

**Model repo (HF):** `mlx-community/parakeet-tdt-0.6b-v2`
- `https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/main/model.safetensors` (2.47 GB, F32)
- `https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/main/config.json` (36 KB)
- `tokenizer.model` (SentencePiece) exists but is **not needed** for transcription —
  the id→piece vocabulary is embedded in `config.json` (`joint.vocabulary`, 1024 entries).

**Reference ports (re-clone to `/tmp/t2-refs/` if gone — they are ephemeral):**
- **Swift (primary scaffold, MIT):** `https://github.com/FluidInference/swift-parakeet-mlx`
  — a complete mlx-swift port (archived but functional; pins mlx-swift 0.25.3, we're on 0.31.4
  so expect minor API drift). Files under `Sources/ParakeetMLX/`:
  - `ParakeetMLX.swift` — config structs + `ParakeetTDT` model class + `loadWeights` +
    `mapSafetensorsKeyToSwiftPath` + `transcribe`/`generate`/`decode` (TDT greedy) +
    `transcribeChunked` + `StreamingParakeet`. **(read in T2.1a — summarized in §5.4)**
  - `AudioProcessing.swift` — featurizer (`getLogMel`, STFT, mel filterbank). **(read — §5.2)**
  - `Conformer.swift` — encoder (subsampling + conformer blocks). **(read in T2.1c)**
  - `Attention.swift` — `RelPositionMultiHeadAttention`. **(read in T2.1c)**
  - `RNNT.swift` — `PredictNetwork` (embed + LSTM) + `JointNetwork`. **(read in T2.1d)**
  - `Tokenizer.swift` — `decode(ids, vocabulary)` (27 lines). **(read in T2.1d)**
- **Python (semantics oracle, Apache-2.0):** `https://github.com/senstella/parakeet-mlx`
  — `parakeet_mlx/{parakeet,conformer,attention,rnnt,audio,tokenizer,alignment}.py`.
  Use to resolve any ambiguity in the Swift port; **the Python and Swift references DIFFER on
  three featurizer details — see §5.2.**

**Our existing Whisper port** (`Relay Notes/Transcription/Whisper*.swift`,
`WhisperAudio.swift`) is a good style reference for porting `mlx-examples` Python → mlx-swift
and for the `nonisolated`/actor/`#if DEBUG` conventions. **Do not reuse Whisper's mel
front-end** (different params; see §5.2).

---

## 5. Architecture specifics

### 5.1 Weight key map (safetensors → module paths)

The 42 distinct key templates from the **device dump** (numeric path components shown as
`{N}`). All F32. This is the exact input to the `mapSafetensorsKeyToSwiftPath` you build:

```
  2×  decoder.prediction.dec_rnn.lstm.{N}.Wh        # 2 LSTM layers (pred net)
  2×  decoder.prediction.dec_rnn.lstm.{N}.Wx
  2×  decoder.prediction.dec_rnn.lstm.{N}.bias
  1×  decoder.prediction.embed.weight              # token embedding (blank-as-pad)
 24×  encoder.layers.{N}.conv.batch_norm.bias       # conformer conv module (×24 layers)
 24×  encoder.layers.{N}.conv.batch_norm.running_mean
 24×  encoder.layers.{N}.conv.batch_norm.running_var
 24×  encoder.layers.{N}.conv.batch_norm.weight
 24×  encoder.layers.{N}.conv.depthwise_conv.weight
 24×  encoder.layers.{N}.conv.pointwise_conv1.weight
 24×  encoder.layers.{N}.conv.pointwise_conv2.weight
 24×  encoder.layers.{N}.feed_forward1.linear1.weight   # macaron FF #1
 24×  encoder.layers.{N}.feed_forward1.linear2.weight
 24×  encoder.layers.{N}.feed_forward2.linear1.weight   # macaron FF #2
 24×  encoder.layers.{N}.feed_forward2.linear2.weight
 24×  encoder.layers.{N}.norm_conv.{bias,weight}
 24×  encoder.layers.{N}.norm_feed_forward1.{bias,weight}
 24×  encoder.layers.{N}.norm_feed_forward2.{bias,weight}
 24×  encoder.layers.{N}.norm_out.{bias,weight}
 24×  encoder.layers.{N}.norm_self_att.{bias,weight}
 24×  encoder.layers.{N}.self_attn.linear_{q,k,v,out,pos}.weight  # rel-pos attention
 24×  encoder.layers.{N}.self_attn.pos_bias_{u,v}    # PER-LAYER (untie_biases=true)
  5×  encoder.pre_encode.conv.{N}.{weight,bias}      # dw-striding subsampling stem
  1×  encoder.pre_encode.out.{weight,bias}           # subsampling output Linear
  1×  joint.enc.{weight,bias}                        # encoder projection
  1×  joint.pred.{weight,bias}                       # prediction projection
  1×  joint.joint_net.{N}.{weight,bias}              # final joint Linear (index 2 in Python)
```

Notes:
- `use_bias=false` for the encoder → encoder Linear/Conv layers have **no bias** (the conv
  `batch_norm` and the norms still have weight+bias; the `joint`/`pred`/`enc` projections have bias).
- `pos_bias_u`/`pos_bias_v` are **per layer** (untied), not shared — 24 each.
- `joint.joint_net` maps to the final Linear (the reference maps `joint_net.2.*` →
  `jointLinear.*`; `joint_net.0` is activation, `.1` identity — skipped).
- The reference's `mapSafetensorsKeyToSwiftPath` (in `ParakeetMLX.swift`) encodes exactly these
  snake_case→camelCase renames. Lift it, adapting property names to whatever you call your modules.

### 5.2 Featurizer (T2.1b) — and THREE port-fidelity risks

Config (`preprocessor`): sample_rate 16000, **n_fft 512**, win_length 400 (= 0.025 s),
hop_length 160 (= 0.01 s), **features 128 mels**, window "hann", `normalize "per_feature"`,
`mag_power 2.0` (power spectrum), log `log(x + 1e-5)`, Slaney mel filterbank (fmin 0, fmax 8000).

Pipeline (from `AudioProcessing.swift` `getLogMel` / `audio.py` `get_logmel`):
1. (optional) pad to `pad_to` (0 here → skip).
2. **preemphasis** (see RISK 1).
3. window (see RISK 2), STFT: reflect-pad `n_fft/2`, `as_strided` frames of `n_fft`, multiply
   by window (zero-padded from win_length 400 → n_fft 512), `rfft` → `[t, n_fft/2+1=257]`.
4. magnitude (see RISK 3), then `pow(mag, 2.0)` (power spectrum).
5. mel: `matmul(melFilterbank[128,257], power.T)` → `log(. + 1e-5)` → `[128, t]`.
6. **per-feature norm:** per-mel-bin z-score across time: `(x - mean_t) / (std_t + 1e-5)`.
7. transpose to `[t, 128]`, add batch dim → `[1, t, 128]`.

**RISK 1 — preemphasis (HIGH) — RESOLVED in T2.1b → apply 0.97.** The config **omits**
`preemph`, but *absent ≠ disabled*: senstella loads the config via `dacite.from_dict`, which
applies the `PreprocessArgs.preemph=0.97` **dataclass default** for any missing key (and NeMo's
`AudioToMelSpectrogramPreprocessor` defaults to 0.97 too), so the model was **trained with
preemph=0.97**. (The FluidInference Swift port reads it as Optional → skips it — confirmed
latent bug.) **Done:** `ParakeetConfig` now decodes absent→0.97 while still honoring a present
value, including explicit `null`→`nil` (distinguished via `container.contains`, mirroring dacite);
`ParakeetAudio.logMel` applies `x = concat([x[:1], x[1:] - 0.97·x[:-1]])`. T2.1a comments +
CHANGE_LOG updated. The T2.1d substring check is still the final arbiter.

**RISK 4 — mel SCALE (Slaney vs HTK) (HIGH; found + resolved in T2.1b, not in the original
three):** the oracle builds the filterbank with `librosa.filters.mel(..., htk=False,
norm="slaney")`. `norm="slaney"` is only the *area* normalization; librosa's **default
`htk=False` also selects the Slaney mel *scale*** (piecewise linear<1 kHz / log above) — two
independent "Slaney" choices. The FluidInference Swift filterbank uses the **HTK** scale
(`2595·log10(1+f/700)`) with Slaney norm — internally inconsistent vs the oracle (another latent
bug, alongside its hann + preemph). **Done:** `ParakeetAudio.melFilterbank` reimplements the
Slaney scale + Slaney area-norm in host `Double` to match librosa exactly. Like the other three,
the T2.1d substring check is the confirmation.

**RISK 2 — hann window variant (MEDIUM):** Python uses `np.hanning(win_length+1)[:-1]` =
**periodic** hann (`0.5 - 0.5·cos(2π k / win_length)`). The FluidInference Swift port uses the
**symmetric** form (`/(n-1)`) — subtly different. Match the Python (periodic). Our
`WhisperAudio.hanning` already implements the periodic form — copy that shape.

**RISK 3 — magnitude L1 vs L2 (MEDIUM):** the Swift port uses `abs(complex)` (true magnitude,
L2). The Python uses a `mx.view`+`[::2]+[1::2]` trick = `|real| + |imag|` (L1 approximation).
These differ. Start with the clean L2 magnitude (`MLX.abs` on the complex rfft output); if the
substring check fails, this is a knob to try.

**Validation (T2.1b smoke section):** compute the mel on `ls_test.flac` (load PCM via the
existing `WhisperAudio.loadPCM` — engine-agnostic 16 kHz mono Float32) and log shape
(`[1, ~670, 128]` for 6.7 s) + value range. Numerical correctness is only *confirmed* by the
end-to-end substring check at T2.1d — the three risks above are the suspects if it's wrong.

### 5.3 FastConformer encoder (T2.1c)

Config (`encoder`): d_model 1024, 24 layers, 8 heads, ff_expansion_factor 4,
**subsampling "dw_striding", subsampling_factor 8, subsampling_conv_channels 256**,
self_attention_model "rel_pos", conv_kernel_size 9, pos_emb_max_len 5000, use_bias false,
xscaling false, conv_norm_type batch_norm.

Read `Conformer.swift` + `Attention.swift` (and `conformer.py`/`attention.py` to resolve
ambiguity). Structure:
- **`pre_encode` (DwStridingSubsampling, factor 8):** input mel `[B, t, 128]` →
  `Conv2d`(k3,s2,p1)→ReLU then depthwise-separable Conv2d pairs, `log2(8)=3` stride-2 stages,
  conv channels 256, then a `Linear(conv_channels·final_freq → d_model=1024)`. Halves time by 8
  (→ one encoder frame per `8·hop=1280` input samples = **0.08 s/frame**).
- **24× ConformerBlock:** macaron — FF1 (½-residual) → rel-pos self-attn → conv module
  (pointwise_conv1 → GLU → depthwise_conv(groups=d_model, k9) → batch_norm → pointwise_conv2)
  → FF2 (½-residual) → final LayerNorm. Pre-LN on each sublayer (`norm_*`).
- **Rel-pos attention:** `RelPositionMultiHeadAttention` (linear_q/k/v/out + linear_pos +
  per-layer pos_bias_u/v). This is the only non-stock op; lift it verbatim from `Attention.swift`.

All ops are native in mlx-swift (`Conv1d`/`Conv2d` w/ groups, `LSTM`, `BatchNorm`, `LayerNorm`,
`rfft`, `asStrided`). **Validation:** run the encoder on the T2.1b mel; log output shape
(`[1, t/8, 1024]`) + timing, and — importantly — the **peak `phys_footprint` during the
forward pass** (reuse the `PeakMemorySampler` pattern from `MLXSmoke.swift`). That peak decides
the entitlement question (§3.1).

### 5.4 TDT greedy decoder (T2.1d) — the correctness gate

Read `RNNT.swift` + `Tokenizer.swift` (and `rnnt.py`). The decode loop (from `ParakeetMLX.swift`
`decode()`, already studied):

- **Prediction network:** `embed(last_token)` (blank-as-pad; `last_token=nil` → blank/zero) →
  2-layer **LSTM** (hidden 640), carrying `(h, c)` state → `decoder_out`.
- **Joint network:** `enc_proj(encoderFrame[step]) + pred_proj(decoder_out)` → ReLU →
  `joint_net` Linear → logits of last-dim **`vocab+1+num_durations = 1024+1+5 = 1030`**.
  Shape `[B, encT=1, predT=1, 1030]`.
- **Split:** vocab head = `logits[...,:1025]` (`argmax`; index **1024 == blank**);
  duration head = `logits[...,1025:]` (`argmax` over 5 → `durations[idx]`, durations `[0,1,2,3,4]`).
- **Rule:** if `predToken != 1024` (not blank): emit token, set `last_token=predToken`, update
  LSTM hidden. Then `step += durations[decision]`.
- **Stuck guard:** `max_symbols=10`; if `durations[decision]==0` increment a counter, and when it
  hits `max_symbols`, force `step += 1`.
- **Timestamps** (for chunking/alignment): `start = step · 8 · 160 / 16000 = step · 0.08 s`,
  duration similarly from `durations[decision] · 0.08 s`.
- **Vocab decode:** `Tokenizer.decode([id], vocabulary)` = `vocabulary[id].replacing("▁", " ")`.
  No SentencePiece runtime needed. `vocabulary` is `config.joint.vocabulary` (1024 entries,
  index 0 = `<unk>`). Join tokens; the `▁`→space handles word boundaries.

**Validation:** the T2.1d smoke decodes `ls_test.flac` end-to-end (featurizer → encoder →
TDT decode → text) and asserts the transcript contains *"openly shouldered the burden"*
(case-insensitive). **This is the gate that confirms the whole port** (and arbitrates the §5.2
risks). Log the transcript + PASS/FAIL.

### 5.5 Long-audio chunking (T2.1e)

Parakeet has no Whisper-style timestamp tokens; the chunking is **different** from Whisper's
`ChunkedTranscription` (do not reuse the `.toTime` advance). From `ParakeetMLX.swift`
`transcribeChunked`: step the audio in windows of `chunkDuration` (e.g. ~120 s) with
`overlap_duration = 15 s`, decode each, offset token timestamps by the chunk start, and **merge
overlapping tokens** across chunk boundaries (the senstella reference uses a longest-common-
subsequence / longest-contiguous merge; the Swift port has a simplified `mergeLongestContiguous`
— port the proper LCS merge from `alignment.py` if the simple one drops/duplicates words at
boundaries). For voice notes this matters less than for hour-long audio; a correct-but-simple
overlap-cutoff merge may suffice for v1 — validate on a tiled clip (like Whisper's
`runWhisperChunked`).

---

## 6. Codebase integration (the provider spine)

`Transcription/Transcriber.swift` defines the contract. To add Parakeet, touch these
(mirror how `.whisperMLX` is wired):

1. **`TranscriptionEngine.swift`** — add `case parakeetMLX` + `displayName`
   (e.g. "On-device (Parakeet)").
2. **`Transcriber.swift`** — add `case parakeetMLX` to the `TranscriptionOptions` enum
   (no decode dials in v1, like `.whisperMLX`). The sum type is compiler-enforced — every
   `switch` over it will tell you what to update (`Tunings.transcriptionOptions`,
   `ReTranscriber.options`, the per-transcriber `guard case` preconditions).
3. **`ParakeetMLXTranscriber`** (new actor, like `WhisperMLXTranscriber`): holds the loaded
   model (cached `LoadedAssets`), implements `transcribe(_:options:)` (file-based) and
   `makeStreamingSession(options:)`. **Use the incremental cast-release loader (§3.1).** Provide
   `nonisolated static let modelDescription = "Parakeet (tdt-0.6b-v2)"`.
4. **`ParakeetStreamingSession`** (like `WhisperStreamingSession`): accumulate PCM during
   `feed`, decode once at `finish()`, `emitsLivePartials = false` (placeholder UX — already built
   in `RecorderView`/`RecorderViewModel` for non-streaming engines).
5. **`TranscriberFactory.swift`** — add a cached slot + arm constructing `ParakeetMLXTranscriber`
   (handed the Parakeet model store). **See T2.4: keep at most one live MLX transcriber.**
6. **`Tunings.swift`** — add a `ParakeetSettings` bundle (empty in v1, like `WhisperSettings`)
   and a `.parakeetMLX` arm in `transcriptionOptions`; extend `reconcileEngineAvailability`
   (see T2.3 — this becomes per-engine).
7. **Settings UI** (`SettingsView.swift` + new `ParakeetModelSection` + `ParakeetSettingsSection`):
   an engine button (disabled until the model is downloaded), a model download/delete section
   (driven by the Parakeet store), and an empty "Recognition" placeholder. Mirror
   `WhisperModelSection`/`WhisperSettingsSection`.
8. **`ReTranscriber.swift`** — add the `.parakeetMLX` arms (availability, options, provenance).
9. **`ContentView.swift`** — construct/inject the Parakeet store (or a unified store registry — see T2.2/T2.3).

Persistence: `Note.transcriptionModel` already stores the provenance label; nothing schema-wise
to change. `Note.deleteWithAudio(in:)` is the canonical delete. SwiftData unchanged.

---

## 7. The dev loops

**Build (compile-check, simulator):**
```sh
xcodebuild build -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | xcbeautify
```

**Test (simulator; MLX tests are gated out):**
```sh
xcodebuild test -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:"Relay NotesTests/<Suite>" 2>&1 | xcbeautify
```
New **test files** must be wired into the pbxproj (the test target is a plain `PBXGroup`):
```sh
ruby scripts/add_test_file.rb <FileName.swift>
```
New **app source files** under `Relay Notes/` are auto-included (file-system-synchronized group)
— including new subdirectories (verified for `Transcription/Parakeet/`). No pbxproj edit needed.

**Device-validate (the only way to run MLX):** build/run the app to the iPhone 15 Pro Max from
Xcode (renew free-tier signing if the 7-day window lapsed), then **Tuning sheet (slider icon) →
Debug → "Run Parakeet smoke (console)"**. Read output in the Xcode console or Console.app
(subsystem `alteredcraft.Relay-Notes`, category `ParakeetSmoke`). The Parakeet weights are
already on the device from T2.1a (`Application Support/parakeet/tdt-0.6b-v2/`), so the smoke
skips the download.

**MLX memory/cache API** (from `mlx-swift` source; confirmed): `MLX.GPU.set(cacheLimit: Int)`,
`MLX.GPU.clearCache()`, `MLX.GPU.set(memoryLimit:relaxed:)`, `MLX.Memory.snapshot()`
(`.activeMemory`/`.cacheMemory`/`.peakMemory`), `MLX.GPU.resetPeakMemory()`. `phys_footprint`
via `task_info(TASK_VM_INFO)` — helper already in `ParakeetSmoke`/`MLXSmoke`.

---

## 8. Remaining work — stage by stage

For each: **goal · do · validate · gotchas · done-when.**

### T2.1b — Mel front-end
- **Do:** `Relay Notes/Transcription/Parakeet/ParakeetAudio.swift` — port `getLogMel` per §5.2
  (STFT, periodic hann, Slaney 128-mel filterbank, power spectrum, log, per-feature norm).
  Add a `ParakeetSmoke` section computing the mel on `ls_test.flac`.
- **Validate:** device smoke logs mel shape `[1, ~670, 128]` + range. (Full correctness deferred
  to T2.1d.)
- **Gotchas:** §5.2 RISKS 1–3 (preemph 0.97, periodic hann, L2 magnitude). Do **not** reuse
  `WhisperAudio` mel (80 mels, n_fft 400, different norm). `loadPCM` from `WhisperAudio` is reusable.
- **Done-when:** mel computes on device with the expected shape; build + simulator tests green.

### T2.1c — FastConformer encoder
- **Do:** `ParakeetEncoder.swift` (+ `ParakeetAttention.swift` if you split rel-pos attention).
  Port subsampling + 24 conformer blocks per §5.3, lifting `Conformer.swift`/`Attention.swift`
  and building the weight key map (§5.1). Implement the **incremental cast-release loader**
  (§3.1) here or in a shared `ParakeetModel.load`. Add a smoke section: load weights into the
  module, run the encoder on the T2.1b mel, log output shape + timing + **peak footprint**.
- **Validate:** encoder output `[1, t/8, 1024]`; **measure forward-pass peak** → decide the
  entitlement (§3.1).
- **Gotchas:** rel-pos attention is the classic port-trap; verify shapes against `attention.py`.
  `use_bias=false`. BatchNorm uses `running_mean/var` (eval mode). mlx-swift 0.31.4 vs the
  reference's 0.25.3 — expect minor API drift (Conv/LSTM signatures).
- **Done-when:** encoder runs on device with correct output shape; peak footprint recorded in
  the smoke + this doc.

### T2.1d — TDT greedy decoder + vocab decode (the gate)
- **Do:** `ParakeetDecoder.swift` (prediction LSTM + joint + duration head) + `ParakeetTokenizer.swift`
  (vocab decode, §5.4). Wire featurizer→encoder→decode end-to-end. Smoke section decodes
  `ls_test.flac` and asserts the substring.
- **Validate:** **substring PASS** on `ls_test.flac` (*"openly shouldered the burden"*). This
  confirms the whole port and arbitrates §5.2 RISKS.
- **Gotchas:** blank index = vocab size (1024). `max_symbols` stuck-guard. LSTM state threading.
  If the substring fails, flip the §5.2 risks in order (preemph → hann → magnitude), then re-check
  joint slicing and the blank index.
- **Done-when:** substring PASS on device; transcript looks right.

### T2.1e — Long-audio chunking
- **Do:** chunk-with-overlap + token merge per §5.5 (own path; not Whisper's `ChunkedTranscription`).
  Smoke: decode a tiled ~36 s clip (like `runWhisperChunked`).
- **Validate:** tiled clip decodes with no dropped/dup words at boundaries.
- **Done-when:** a >chunk-length clip transcribes correctly on device.

### T2.2 — Generalize the download store
- **Do:** extract the generic machinery from `WhisperModelStore` into
  `DownloadableModelStore(spec:)` where a spec = {remote files [{url, sha256, size}], bundled
  files, subdirectory, weights filename}. `WhisperModelStore` becomes `spec: .whisperSmallEn`;
  Parakeet gets `spec: .parakeetTDT06bV2` (manifest: `model.safetensors` 2.47 GB + `config.json`;
  no separate bundled assets needed — Parakeet config is downloaded, not bundled, unlike Whisper).
  Pin a SHA-256 for the Parakeet weights. **Add the §3.4 robustness** (resume, background session).
  Replace the throwaway downloader in `ParakeetSmoke` with the store. Update `WhisperModelStoreTests`.
- **Validate:** both models download/verify/delete via one store type; simulator tests green.
- **Done-when:** Parakeet weights download through the real store with integrity check + a generic
  error UX.

### T2.3 — Per-engine gating
- **Do:** replace the single `whisperReady: Bool` with per-engine readiness. Touches
  `Tunings.reconcileEngineAvailability`, `ReTranscriber.isAvailable`/`availableEngines`,
  `SettingsView` engine buttons, `ContentView` store wiring. Apple → always; Whisper/Parakeet →
  their model ready.
- **Done-when:** each engine gates independently; deleting either model reverts selection correctly.

### T2.4 — Single live MLX engine (eviction)
- **Do:** `TranscriberFactory` keeps at most one live MLX-backed transcriber; evict the previous
  on engine switch (you never transcribe with two at once). Prevents Whisper(~0.5 GB) + Parakeet
  (~1.2 GB) co-residency. Consider `MLX.GPU.set(cacheLimit:)` as the secondary lever.
- **Done-when:** switching engines releases the prior model (verify via a smoke/footprint check).

### T2.5 — Wire end-to-end
- **Do:** all of §6 — enum/options/factory arms, `ParakeetStreamingSession`, Settings sections,
  provenance, `ReTranscriber` arms, tests (wire via `add_test_file.rb`, gate MLX tests).
- **Validate:** select Parakeet in Settings, record on the phone, get a transcript; re-transcribe
  an existing note with Parakeet; confirm provenance label on the `Note`.
- **Done-when:** Parakeet is selectable and produces transcripts on the iPhone 15 Pro Max
  (the T2 done-when).

---

## 9. Conventions & gotchas checklist

- [ ] **MLX is device-only** — gate tests `#if !targetEnvironment(simulator)`; numerics validate via `ParakeetSmoke`.
- [ ] **Incremental cast-release load** (cacheLimit 0; mutate the dict you iterate) — never load-then-cast-all (§3.1).
- [ ] **`os.Logger.notice(... privacy: .public)`** for device output (durable); log metadata before risky ops.
- [ ] **`nonisolated protocol`** for any isolation-neutral protocol (project default is `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); MLX transcriber is an `actor`.
- [ ] **New app files auto-included**; new **test files** need `ruby scripts/add_test_file.rb`.
- [ ] **User-facing errors are generic + actionable**; full detail to logs only (see `Projects/CLAUDE.md`).
- [ ] **No default fallbacks for required config**; fail fast with a helpful message.
- [ ] **Edit `.xcodeproj` via the `xcodeproj` Ruby gem**, validate on a `/tmp` copy first (if you must touch it beyond test wiring).
- [ ] **Append a `CHANGE_LOG.md` entry per shippable stage**; update this doc's §1 table.
- [ ] **Preserve the provider spine** (§3.5/§6) — add engines by the established shape.
- [ ] **Keep `transcribe(_:options:)`** (file-based) — it's the re-transcribe path and Parakeet's natural fit.

---

## 10. Open questions / pending decisions

1. ~~**preemph 0.97 vs none** (§5.2 RISK 1)~~ — **RESOLVED in T2.1b: 0.97** (dacite applies the
   absent-key dataclass default; `ParakeetConfig` + comments/CHANGE_LOG updated). Final confirmation
   is still the T2.1d substring check — also the arbiter for the §5.2 hann / magnitude / mel-scale risks.
2. **`increased-memory-limit` entitlement** — decide after T2.1c measures the forward-pass peak (§3.1).
3. **Chunk merge sophistication** (§5.5) — simple overlap-cutoff vs full LCS; decide from a tiled-clip test.
4. **bf16 vs a pre-converted on-disk format** — we cast F32→bf16 at load each launch (~fast, lazy). If
   load time grates, consider converting once to a bf16 safetensors on disk (T2.2 could own this), so
   subsequent loads mmap bf16 directly (~1.2 GB, no cast). Not needed for v1.
5. **Accuracy ladder validation** — once selectable (T2.5), run the same audio through Apple/Whisper/
   Parakeet via `NoteDetailView`'s re-transcribe (the A/B substrate) to confirm Parakeet earns its place.
```
