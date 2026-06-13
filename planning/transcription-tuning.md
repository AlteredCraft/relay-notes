---
title: Relay Notes - Transcription Tuning
date: 2026-06-08
updated: 2026-06-12
tags:
  - altered-craft
  - voice
  - stt
  - transcription
  - tuning
  - apple-speech
  - speech-analyzer
  - mlx
  - whisper
status: living
created_by: build-log
---

# Relay Notes: Transcription Tuning

Companion to [notes.md](./notes.md). Explains every knob that affects transcription — what it does, what we picked, and **why**. The empirical per-knob outcomes live in [notes.md Appendix B](./notes.md#b-v11-accuracy-tuning-empirical-log); the dated decision record is the [Appendix](#appendix-decisions-log) at the bottom.

> [!info] Scope
> Two on-device engines are live: **Tier 1 — Apple `SpeechTranscriber`** (via `SpeechAnalyzer`) and **Tier 2 — Whisper `small.en` via raw `mlx-swift`** (shipped + device-validated through 2026-06-12). **Tier 3 — Cloud STT** (Cohere / Gemini) is future (T3 in notes.md). Each engine's tunable surface differs — see "Engine relevance" below.

---

## The dials, at a glance

Runtime-tunable from the in-app **Settings sheet** (slider icon, top-right). State persists via `UserDefaults`, mediated by `Tunings` (`Recording/Tunings.swift`).

| # | Dial | Layer | Range / values | Default |
|---|---|---|---|---|
| 1 | Audio session mode | `AVAudioSession.Mode` | `.default` / `.measurement` / `.voiceChat` / `.videoRecording` | `.default` |
| 2 | AAC bitrate | Encoder (`AVAudioFile` AAC settings) | 32 / 64 / 96 / 128 / 192 kbps | 64 kbps |
| 3 | Transcription preset | `SpeechTranscriber.Preset` | `transcription` / `transcriptionWithAlternatives` / `progressiveTranscription` | `transcription` |
| 4 | Contextual biasing | `AnalysisContext.contextualStrings[.general]` | comma-separated words/phrases | empty |

**Engine relevance (Approach C).** Dials 1–2 are *capture / storage* — they shape the recorded audio and apply to whichever engine transcribes it (and bitrate only affects the saved `.m4a` you play back, **not** transcription, since both engines work from the live PCM). Dials 3–4 are *Apple-Speech-specific* recognition settings — `SpeechTranscriber` concepts with no Whisper analog wired — so they have **no effect** under Whisper. The Settings sheet mirrors this: shared **Capture** + **Storage & playback** groups always show, while an engine-specific **Recognition** group swaps with the selection (Whisper exposes no decode dials in v1). Per-engine settings live in bundles (`AppleSpeechSettings` / `WhisperSettings`) on `Tunings`. See the [Decisions log](#appendix-decisions-log) 2026-06-12 / [issue #3](https://github.com/AlteredCraft/relay-notes/issues/3).

There are also **non-tunable** knobs set in code — see "Hidden knobs."

---

## Tier 1 dials (Apple Speech) — what & why

### 1. Audio session mode

Selects how iOS preprocesses the mic before our code sees it.

| Mode | Behavior | Use for |
|---|---|---|
| `.default` | AGC + noise suppression | General notes; comfortable playback |
| `.measurement` | Raw — no AGC, no noise gate | STT-only testing in quiet rooms (quieter playback) |
| `.voiceChat` | VoIP echo cancellation + AGC | Talking-to-someone scenarios |
| `.videoRecording` | Camera-style processing | Camera-like dynamics |

**Default `.default`.** Shipped first as `.measurement` (hypothesis: raw signal helps STT in noise); real-world testing showed quiet playback with no observable STT win. Reverted 2026-06-08. **Cheap** knob — try first when audio quality feels off.

### 2. AAC bitrate

Encoding bitrate for the `.m4a` written by `LiveAudioEngine`. **Default 64 kbps mono** (~480 KB/min). Does **not** affect transcription — both engines transcribe the live PCM, not the saved file — so this is a playback/storage dial. Bump to 96–128 kbps for long-form keepers. **Cheap.**

### 3. Transcription preset

Highest-leverage Apple dial, clearest accuracy tradeoff. The presets are sugar over `transcriptionOptions` / `reportingOptions` / `attributeOptions`:

| Preset | `volatileResults` | `fastResults` | Notes |
|---|---|---|---|
| `transcription` | No | No | Accuracy-first; final results only |
| `transcriptionWithAlternatives` | No | No | + per-word alternates (future tap-to-correct UX) |
| `progressiveTranscription` | Yes | Yes | Live partials, smaller context → lower accuracy by design |

**Default `transcription`** — most accurate stored transcript, and we get live partials anyway via the streaming override (below) without the `fastResults` hit. Use `transcriptionWithAlternatives` if/when a correction UI lands; avoid `progressiveTranscription` unless you specifically want its lower-latency/lower-accuracy character. **Medium** cost.

### 4. Contextual biasing

Whitelist of domain words/phrases to `AnalysisContext.contextualStrings[.general]`. **Default empty. Status: untested** — documented for `DictationTranscriber`, effect on `SpeechTranscriber` empirically unclear. Worth a structured A/B on proper-noun-heavy text (`AlteredCraft`, `MLX`, `Qwen`) once there's a stable corpus. **Low effort to set, high effort to validate.**

---

## Hidden knobs (set in code, not the UI)

### Streaming override: union `.volatileResults` into the user's preset

In `AppleSpeechTranscriber.makeStreamingSession`, the streaming `SpeechTranscriber` is built from the user's preset options *plus* `.volatileResults`:

```swift
reportingOptions: options.preset.reportingOptions.union([.volatileResults])
```

**Why.** Without it, basic `.transcription` emits no intermediate results — the live partial card stays empty. Switching to `.progressiveTranscription` to fix that drags in `fastResults`, which dings accuracy on every result including the final. Unioning just `.volatileResults` gives partials without `fastResults`. The persisted `Note.transcript` comes from finalized chunks only, so stored accuracy matches the preset's intent.

### Sample-rate conversion: `AVAudioConverter` at default quality

`LiveAudioEngine` runs tap buffers (typically 48 kHz hardware) through `AVAudioConverter` to the analyzer's format (typically 16 kHz mono Float32). Default (medium) quality. **Hypothesis to test:** `converter.sampleRateConverterQuality = .max` may close any subtle streaming-vs-file gap. Untested — knob #1 to turn if a streaming-only regression ever appears.

### Buffer size: 4096 frames

`installTap(bufferSize: 4096)` → ~85 ms/buffer at 48 kHz. The analyzer is meant to be agnostic to chunk boundaries within reason. Untested whether smaller (more responsive) or larger (less overhead) changes anything.

---

## Streaming vs file-based: should we expect different accuracy?

**Tier 1 (Apple)** shares one `AppleSpeechTranscriber` across two paths:

1. **Streaming** (`makeStreamingSession`) — used by the recorder; PCM fed live into `SpeechAnalyzer.start(inputSequence:)`.
2. **File-based** (`transcribe(_:options:)`) — used by nothing today; reserved for cloud STT and re-transcribe.

In theory both converge on the same finalized transcript (finalization is the same op). In practice two subtleties favor file-based: it lets Apple handle resampling internally (vs our `AVAudioConverter`), and it sees one continuous read vs chunked `AnalyzerInput`. **Mitigation:** the stored AAC is identical in both paths, so a stored note can always be re-transcribed via the file-based path later — worth a "re-transcribe" debug action if divergence shows up in real use.

**Tier 2 (Whisper)** collapses the distinction to one path: buffers fed via `feed(_:)` accumulate in memory until `finish()`, then a single file-style decode runs over the whole recording. No volatile-then-final because there are no intermediate emits — it's "file-based pretending to be streaming" for protocol-shape compatibility. The file-based `transcribe(_:options:)` can likewise decode an existing URL — the basis for a future "re-transcribe with Whisper" action.

---

## Tier 2 — Local Whisper via MLX

**Status: shipped + device-validated + measured** (T1.0–T1.3, through 2026-06-13). Engine `WhisperMLXTranscriber`, built on raw `mlx-swift` (*not* WhisperKit — see Decisions log 2026-06-10). The model is **downloaded from `mlx-community/whisper-small.en-fp16`** (`model.safetensors`, ~481 MB FP16, pinned commit + SHA-verified) into Application Support on first use — weights are no longer bundled. Validated 2026-06-10 to load + run on the iPhone 15 Pro Max without the `increased-memory-limit` entitlement. **T1.3 numbers (2026-06-13): ~4× realtime decode (5-min note ≈ 80 s), memory bounded + flat across note length (~2.8 GB footprint, mostly reclaimable MLX buffer cache; ~464 MB live model), `small.en` retained as default** — full table in [notes.md Appendix C](./notes.md#c-t1-measurements--whisper-smallen-on-device-t13).

### Model-side choices (not user-exposed — one valid value each in v1)

- **Model variant:** `whisper-small.en` only. `tiny.en` was removed 2026-06-10 (T1.2a) once `small.en` validated without the entitlement; if a second variant ever returns we re-add the enum.
- **Language:** `en` only — the English-only build (`gpt2.tiktoken` vocab + English special tokens). Multilingual would need a different vocab + decode path.

### Hidden defaults (the Whisper port's load-bearing choices)

- **In-memory PCM, decode once at `finish()`.** ~115 MB resident for a 30-min note on the 15 Pro Max — comfortable on 8 GB, bound is real but not load-bearing for v1 notes. Revisit trigger in [#1](https://github.com/AlteredCraft/relay-notes/issues/1).
- **Greedy decode (beam size 1).** Beam search costs latency for a small accuracy bump. T1.3 (2026-06-13) settles the tradeoff against it for now: decode is already ~4× realtime (5-min note ≈ 80 s) and the test clip decodes verbatim-correct, so paying multiples of that latency for a marginal accuracy gain isn't worth it. Revisit only if a daily-use accuracy gap appears.
- **Long audio: timestamp-guided 30-s seek loop (T1.2d-1).** Whisper's encoder takes exactly 30 s; longer audio is walked window-by-window, each window restarting at the previous one's last *complete* segment boundary (from the decoder's timestamp tokens) so words aren't cut at arbitrary 30-s edges. The driver (`ChunkedTranscription` + `AudioWindow`) is model-agnostic; the timestamp parsing (`WhisperDecoding.parseWindow`) is Whisper-specific.
- **Silence skip: `no_speech_threshold = 0.6`, overridden by `avg_logprob > -1.0`.** Drops a window whose `<|nospeech|>` prob beats 0.6 — unless the decode is confident anyway (protects quiet-but-real speech). Reference defaults; revisit with dogfood data (voice notes have long pauses, so this runs often).
- **`max_initial_timestamp = 1.0 s`.** Each window's first segment must start within 1 s — reference default; stops the model "explaining away" a window start as silence.
- **`condition_on_previous_text`: not ported.** The reference feeds each window's text into the next window's prompt for consistency, but it's the known repetition-loop failure source and its safety net is the temperature-fallback machinery we don't have (greedy-only). Windows decode independently. Revisit only with dogfood evidence of boundary inconsistency.
- **No streaming partials.** `updates` emits zero values during `feed` and exactly one final on `finish()`. Chunked partials are a follow-up, gated on the in-memory bound (issue #1) or the no-partials UX feeling bad in dogfood.

### Recording UX while Whisper is selected (shipped T1.2f)

Whisper emits zero partials, so `RecorderView` replaces the live transcript card with a placeholder — "Transcript will appear when you stop recording." + a live mic-level meter + an elapsed-time label. On stop, `.finalizing` runs the full-file decode behind a "Transcribing…" spinner (no percentage — no clean progress signal without chunking).

### Model lifecycle

- **Application Support**, not Caches (Caches are evictable — a redownload from a coffee shop is bad). Excluded from iCloud backup.
- Pre-download + delete from Settings — preserves the offline-recording promise once installed (zero network calls during a recording session). Delete asks for confirmation (480 MB / re-download).
- **Gating, not a record-time block:** Whisper can't be *selected* without its model on disk — the engine row is disabled until ready, and deleting reverts the selection to Apple (`Tunings.reconcileEngineAvailability`).

---

## Open questions

- Does `converter.sampleRateConverterQuality = .max` change the final streaming transcript at all?
- Does `contextualStrings[.general]` actually bias `SpeechTranscriber` (vs only `DictationTranscriber`)? Needs a proper-noun-heavy A/B.
- How much does buffer size (4096 → 1024 / 8192) move latency-of-first-partial vs accuracy?
- Should a "re-transcribe with cloud/Whisper" action live in `NoteDetailView`, leaning on the file-based `transcribe(_:options:)`?

## How to test a dial

1. Pick a representative ~30 s recording (ideally already on the phone).
2. Change one knob in Settings.
3. Record the same content; diff transcripts.
4. Log the outcome in [notes.md Appendix B](./notes.md#b-v11-accuracy-tuning-empirical-log) — *this* doc explains the dials; *that* table records what turning them did.

---

## Appendix: Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-06-08 | Audio session mode default `.measurement` → `.default` | `.measurement` gave quiet playback with no observable STT win |
| 2026-06-08 | AAC bitrate default 64 kbps mono | Voice-grade; balances size and fidelity |
| 2026-06-08 | Transcription preset default `.transcription` | Maximize stored-transcript accuracy; live UX comes from the streaming override, not the preset |
| 2026-06-08 | Streaming session unions `.volatileResults` into the preset | Live partials without dragging in `fastResults` (which would reduce accuracy) |
| 2026-06-08 | `AVAudioConverter` left at default quality | Default works; revisit if a streaming-only regression appears |
| 2026-06-08 | Contextual biasing empty default | Effect on `SpeechTranscriber` (vs `DictationTranscriber`) undocumented/untested; off until there's a corpus |
| 2026-06-10 | Tier 2 engine: raw `mlx-swift`, not WhisperKit | One ML runtime (avoid Core ML + MLX when L1 lands); pays the MLX-on-iOS cost on a smaller problem than an LLM; transferable to Parakeet/Qwen3-ASR. Escape valve to WhisperKit behind the same protocol if intractable |
| 2026-06-10 | Tier 2 default model `whisper-small.en` | ~481 MB FP16, English-only, good accuracy/footprint balance |
| 2026-06-10 | Tier 2 first cut: no streaming partials (finalize-only) | Chunked streaming is its own design problem; ship no-partials first, revisit if dogfood demands it |
| 2026-06-10 | Tier 2 buffer strategy: in-memory PCM during recording | Simpler than a scratch WAV; fine to ~30 min on the 15 Pro Max. Revisit trigger in [#1](https://github.com/AlteredCraft/relay-notes/issues/1) |
| 2026-06-10 | `TranscriptionOptions` becomes a sum type (`.apple` / `.whisperMLX`) | Two engines, different parameter sets; sum is type-safe with no nullable fields and matches `TranscriptionEngine` |
| 2026-06-10 | T1.1 split into T1.1a (mlx-swift "hello on device") + T1.1b (Whisper transcript) | `mlx-swift-examples` has no Whisper reference (issue #146); the real reference is `ml-explore/mlx-examples` Python — a port, not a copy-paste. T1.1a derisks the SPM dep + Metal link before the multi-day port |
| 2026-06-10 | Source repo `mlx-community/whisper-small.en-fp16` (not the `-mlx` sibling) | The `-fp16` repo ships `model.safetensors` directly; the `-mlx` repo ships npz that `mlx-swift`'s `loadArrays` can't read without an npz→safetensors conversion step |
| 2026-06-10 | Dropped `tiny.en` support entirely (T1.2a) | `small.en` validated as the production default with no variant picker planned; `tiny.en` was dead code (variant enum, `Tunings.whisperModelVariant`, `WhisperMLXOptions` fields). Re-adding the enum is cheap if a second variant returns |
| 2026-06-10 | Whisper assets parametrized by `WhisperModelLocation` (T1.2a) | `nonisolated enum` with `.bundled` (dev) and `.directory(URL)` (download path). Loaders take a location with no default — every call site declares it; `WhisperModelStore` injects the downloaded dir |
| 2026-06-11 | Long audio: timestamp-guided seek loop, model-agnostic driver (T1.2d-1) | `padOrTrim` truncates at Whisper's 30-s window (silent-truncation risk, surfaced in T1.2c). Ported the reference's seek loop with windowing split model-agnostic (`AudioWindow` + `ChunkedTranscription`) so a future model swaps a window spec, not the loop |
| 2026-06-11 | Timestamp rules ported with OpenAI semantics, not mlx-examples' | The mlx-examples `ApplyTimestampRules` monotonicity rule has an index-vs-value bug that no-ops it (masks an empty range). Ported `openai/whisper`'s version: mask timestamp *values* below the last emitted one |
| 2026-06-11 | `condition_on_previous_text` not ported (windows decode independently) | The documented repetition-loop source; its recovery is temperature fallback, which greedy-only doesn't have. Independent windows trade a little cross-boundary consistency for immunity to the failure mode |
| 2026-06-12 | Settings + `Tunings` restructured into shared vs engine-specific groups (Approach C) | With two engines, the Apple-only dials rendered as live no-ops under Whisper. Per-engine settings now live in bundles mirroring `TranscriptionOptions`; the UI swaps a per-engine Recognition group while Capture / Storage stay shared. UserDefaults keys unchanged (no migration). Sets up T2/T3 to add an engine via a bundle + section + switch arm. See [issue #3](https://github.com/AlteredCraft/relay-notes/issues/3) |
| 2026-06-13 | Keep `whisper-small.en` as the default after T1.3 measurements | On-device numbers (iPhone 15 Pro Max): ~4× realtime decode (5-min note ≈ 80 s), accurate (substring PASS), memory bounded + flat across note length (~2.8 GB footprint, of which ~2.2 GB is reclaimable MLX buffer cache and only ~464 MB is the live model), runs without the `increased-memory-limit` entitlement. Numbers don't justify stepping down to a smaller variant. If jetsam headroom is ever needed (e.g. concurrent L1 MLX LLM), the first lever is `MLX.Memory.set(cacheLimit:)`, not a smaller model. Full table in [notes.md Appendix C](./notes.md#c-t1-measurements--whisper-smallen-on-device-t13) |
| 2026-06-13 | T2 second on-device engine: **Parakeet `tdt-0.6b-v2` via raw `mlx-swift`** (not Qwen3-ASR) | Best English WER of the candidates; a complete MIT mlx-swift reference port already exists (`FluidInference/swift-parakeet-mlx`, cross-checked vs the Python `senstella/parakeet-mlx`); every op it needs is native in mlx-swift; weights load straight from safetensors (no npz→safetensors conversion the Whisper port needed). Qwen3-ASR is a bigger port surface with no Swift reference and autoregressive decode (no TDT frame-skip) — kept as sanity-check only |
| 2026-06-13 | Parakeet weights loaded by **incremental cast-and-release**, not load-then-cast-all | Parakeet ships F32 only (`mlx-community/parakeet-tdt-0.6b-v2`, 2.47 GB, 617M params). The reference `loadParakeetModel` loads F32 into the module then casts *all* params and `update`s — holding F32 + bf16 ≈ 3.7 GB, which OOMs the 8 GB iPhone at the ~3 GB no-entitlement ceiling (observed: jetsam at 3.1 GB). Casting tensor-by-tensor and releasing each F32 source (with `MLX.GPU.set(cacheLimit: 0)` so freed buffers return to the OS) holds the resident floor at **~1.2 GB** — device-validated in T2.1a, off the `increased-memory-limit` entitlement like Whisper. The entitlement is now gated on the forward-pass activation peak (T2.1c), not the weights |
