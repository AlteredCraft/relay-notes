---
title: Relay Notes - Transcription Tuning
date: 2026-06-08
updated: 2026-06-10
tags:
  - altered-craft
  - voice
  - stt
  - transcription
  - tuning
  - apple-speech
  - speech-analyzer
status: living
created_by: build-log
---

# Relay Notes: Transcription Tuning

Companion to [notes.md](./notes.md). Tracks every knob that affects transcription accuracy and live UX, what each one does, what we picked, and why. Updated as we test on real audio.

> [!info] Scope
> v1 uses Apple's on-device `SpeechTranscriber` (via `SpeechAnalyzer`) — Tier 1 below. Tier 2 (Local ASR via MLX, Whisper first) is **next up as T1** in [notes.md § Transcription upgrades](./notes.md#transcription-upgrades-ahead-of-l-stages). Tier 3 (Cloud STT, Cohere / Gemini) follows. Each provider gets its own section here as it comes online.

---

## The dials, at a glance

All four are runtime-tunable from the in-app **Tuning sheet** (slider icon, top-right of the navigation bar). State persists across launches via `UserDefaults` and is mediated by `Tunings` (`Recording/Tunings.swift`).

| # | Dial | Layer | Range / values | Current default |
|---|---|---|---|---|
| 1 | Audio session mode | `AVAudioSession.Mode` | `.default` / `.measurement` / `.voiceChat` / `.videoRecording` | `.default` |
| 2 | AAC bitrate | Encoder (`AVAudioFile` AAC settings) | 32 / 64 / 96 / 128 / 192 kbps | 64 kbps |
| 3 | Transcription preset | `SpeechTranscriber.Preset` | `transcription` / `transcriptionWithAlternatives` / `progressiveTranscription` | `transcription` |
| 4 | Contextual biasing | `AnalysisContext.contextualStrings[.general]` | Comma-separated words/phrases | empty |

There are also **non-tunable** knobs we set in code — see "Hidden knobs" below.

---

## 1. Audio session mode

**What it does.** Selects how iOS preprocesses the mic input before our code sees it.

| Mode | Behavior | Use for |
|---|---|---|
| `.default` | Standard processing — AGC (auto-gain control), noise suppression | General notes, anything you also want to play back comfortably |
| `.measurement` | Raw signal — no AGC, no noise gate | STT-only testing in quiet rooms; *not* good for playback (noticeably quieter) |
| `.voiceChat` | VoIP echo cancellation, AGC | Talking-to-someone scenarios |
| `.videoRecording` | Camera-style audio processing | Recording with camera-like dynamics |

**Default: `.default`.** Initially shipped as `.measurement` based on a hypothesis that raw signal would help STT in noisy rooms. Real-world testing showed playback was uncomfortably quiet with no observable STT win. Reverted to `.default` on 2026-06-08. `.measurement` stays available for opt-in STT-focused testing.

**Knob cost: cheap.** Try this first when audio quality feels off.

---

## 2. AAC bitrate

**What it does.** Encoding bitrate for the `.m4a` file written to disk by `LiveAudioEngine`. Lower = smaller files, less audio fidelity. Higher = bigger files, more fidelity.

**Default: 64 kbps mono.** Voice-grade default — ~480 KB per minute. Higher bitrates have not yet been shown to improve STT accuracy in our tests; the transcriber works from PCM buffers in the streaming path anyway (see "Hidden knobs"), so file bitrate primarily affects *playback* fidelity in `NoteDetailView`, not transcription.

**Knob cost: cheap.** Worth bumping to 96–128 kbps if you start using these as long-form recordings rather than throwaway notes.

---

## 3. Transcription preset

This is the highest-leverage knob, and the one with the clearest accuracy tradeoff.

Per Apple's docs, the presets are sugar over three option sets: `transcriptionOptions`, `reportingOptions`, `attributeOptions`. The interesting bits for us:

| Preset | `volatileResults` | `fastResults` | Notes |
|---|---|---|---|
| `transcription` | No | No | Designed for accuracy. No live partials. Final results only. |
| `transcriptionWithAlternatives` | No | No | Same as above + per-word alternates (for a future tap-to-correct UX) |
| `progressiveTranscription` | Yes | Yes | Live partials, smaller context window → lower accuracy by design |

**Default: `transcription`.** We want the most accurate final transcript on a stored note. We do *not* accept the `fastResults` accuracy hit just to get partials, because…

**See "Streaming override" below.** In the streaming path we union `.volatileResults` into the preset's reporting options regardless of which preset the user picks. This gives live partials without dragging in `fastResults`. So picking `transcription` in the UI now gets you live word-by-word *and* the accuracy floor.

**Knob cost: medium.** Use `transcriptionWithAlternatives` if/when we build a correction UI. Avoid `progressiveTranscription` unless you specifically want the lower-latency-lower-accuracy character of the full progressive preset.

---

## 4. Contextual biasing

**What it does.** Whitelist of domain words/phrases passed to `AnalysisContext.contextualStrings[.general]` to nudge the recognizer toward them.

**Default: empty.**

**Status: untested.** Documented for `DictationTranscriber`; effect on `SpeechTranscriber` is empirically unclear. Worth a structured A/B with proper-noun-heavy text (people's names, jargon: `AlteredCraft`, `MLX`, `Qwen`) once we have a stable test corpus.

**Knob cost: high effort to validate, low effort to set.** Edit the comma-separated text field.

---

## Hidden knobs (set in code, not in the UI)

These also affect quality but we don't expose them.

### Streaming override: union `.volatileResults` into the user's preset

Added 2026-06-08 in `AppleSpeechTranscriber.makeStreamingSession`. Builds the streaming `SpeechTranscriber` from the user's preset's options *plus* `.volatileResults`:

```swift
SpeechTranscriber(
    locale: supportedLocale,
    transcriptionOptions: options.preset.transcriptionOptions,
    reportingOptions: options.preset.reportingOptions.union([.volatileResults]),
    attributeOptions: options.preset.attributeOptions
)
```

**Why.** Without `.volatileResults`, the basic `.transcription` preset emits no intermediate results — the live partial card in `RecorderView` stays empty during recording. Switching to `.progressiveTranscription` to fix that brings `fastResults` along for the ride, which dings accuracy on every result (including the final). Unioning just `.volatileResults` gives partials without `fastResults`. Best of both.

**Side effect on accuracy.** `volatileResults` only adds tentative results during the volatile range; finalized results are unchanged. The transcribed string we persist to `Note.transcript` comes from finalized chunks only, so accuracy of the *stored* transcript should match the preset's intended accuracy.

### Sample-rate conversion: `AVAudioConverter` at default quality

`LiveAudioEngine` runs tap buffers (typically 48 kHz hardware) through `AVAudioConverter` to the analyzer's preferred format (typically 16 kHz mono Float32 from `SpeechAnalyzer.bestAvailableAudioFormat`). The converter currently uses its default settings.

**Why this matters.** In the file-based path (`AppleSpeechTranscriber.transcribe(_:options:)`), `SpeechAnalyzer.analyzeSequence(from:)` does its own internal decoding/resampling with whatever quality it considers appropriate. In the streaming path, *we* are doing the resampling, and the default `AVAudioConverter` quality is medium.

**Hypothesis to test.** Setting `converter.sampleRateConverterQuality = .max` may close any subtle quality gap between streaming and file-based final transcripts. Untested. If we ever observe a streaming-only accuracy regression, this is knob #1 to turn.

### Buffer size: 4096 frames

`inputNode.installTap(onBus: 0, bufferSize: 4096, format: ...)`. At 48 kHz that's ~85 ms per buffer. The analyzer is supposed to be agnostic to chunk boundaries within reason. Untested whether smaller (more responsive) or larger (less overhead) changes anything.

---

## Streaming vs file-based: should we expect different accuracy?

This section is about **Tier 1 (Apple Speech)** — where two transcription paths share one `AppleSpeechTranscriber`:

1. **Streaming** (`makeStreamingSession`) — used by the recorder. PCM buffers fed live into `SpeechAnalyzer.start(inputSequence:)` while recording.
2. **File-based** (`transcribe(_:options:)`) — used by nothing in the app right now. Reserved for the future cloud STT path and for re-transcribing existing notes.

**In theory** they converge on the same finalized transcript for the same preset, because finalization is the same operation in both cases — analyzer settles its volatile range, emits final results.

**In practice**, two subtleties favor file-based:

- File-based lets Apple handle resampling internally. Streaming uses our `AVAudioConverter`. See "Sample-rate conversion" above.
- Streaming sees chunked input (one `AnalyzerInput` per ~85 ms buffer). File-based sees one continuous read. The analyzer claims to handle this, but it's an extra surface.

**Mitigation.** Storage of the audio file is identical in both paths — same AAC m4a written by `LiveAudioEngine`. So we can always re-transcribe a stored note via the file-based path later if we suspect the streaming pass mis-transcribed something. Worth building a "re-transcribe" debug action if we start seeing divergence in real use.

### Tier 2 (Whisper) — different shape

For `WhisperMLXTranscriber` the streaming/file-based distinction collapses to one path: buffers fed via `feed(_:)` accumulate in memory until `finish()`, at which point a single file-style decode runs over the whole recording. There's no concept of volatile-then-final because there are no intermediate emits. Net: Tier 2 is "file-based-pretending-to-be-streaming" for protocol-shape compatibility. The protocol's `transcribe(_:options:)` file-based method can also be implemented to decode an existing audio URL directly — useful if we later want a "re-transcribe with Whisper" debug action against notes captured under Apple Speech.

---

## Tier 2 — Local ASR via MLX (Whisper)

**Status: T1.1 shipped (file-based transcribe on device, 2026-06-10), T1.2 in progress.** Engine is `WhisperMLXTranscriber`, built on `mlx-swift` (raw — *not* WhisperKit; see "Decisions log" 2026-06-10 for why). Default model `mlx-community/whisper-small.en-mlx` (~250 MB downloaded → ~481 MB FP16 resident) — empirically validated 2026-06-10 to load and run on iPhone 15 Pro Max without the `increased-memory-limit` entitlement, removing the prior free-tier-sideload watch-item. The dials and defaults below are still the *plan* until T1.2 lands the recorder wiring + download UX — empirical outcomes get appended once that ships.

### The dials

| # | Dial | Range / values | Current default |
|---|---|---|---|
| 1 | Model variant | `whisper-small.en` only — `tiny.en` was removed 2026-06-10 (T1.2a) after on-device validation showed `small.en` runs without the increased-memory-limit entitlement. No UI picker; if a second variant ever returns we re-add the enum | `small.en` |
| 2 | Language | `en` only — Whisper assets are the English-only build (`gpt2.tiktoken` vocab + English-only special tokens). Multilingual would require a different vocab + decode path | `en` |

Neither is user-exposed — there's only one valid value for each in v1. They live in the dials table because they're the load-bearing model-side choices.

### Hidden defaults

- **In-memory PCM buffer during `feed`, decode once at `finish()`.** Notes up to ~30 min on the iPhone 15 Pro Max use roughly 115 MB of resident PCM — comfortable on 8 GB. Bound is real, just not load-bearing for v1-style notes. Revisit trigger and alternative buffer strategies tracked in [#1](https://github.com/AlteredCraft/relay-notes/issues/1).
- **Greedy decoding (beam size 1) for the first cut.** Beam search costs latency for a small accuracy bump; not worth the complexity until we have on-device numbers to anchor the tradeoff.
- **No streaming partials in the first cut.** The `TranscriptionSession.updates` stream returned by `WhisperMLXTranscriber.makeStreamingSession` emits zero values during `feed` and exactly one final value on `finish()`. Chunked streaming partials are a follow-up, gated on the in-memory bound becoming a real problem (issue #1) or the no-partials UX feeling bad in dogfood.

### Recording UX while Whisper is the selected engine

- The live partial transcript card is **replaced** by a placeholder: "Transcript will appear when you stop recording." + elapsed-time label + audio level meter.
- After the user stops, the existing `.finalizing` state runs the full-file decode. UI shows a spinner with "Transcribing…" — no progress percentage (Whisper doesn't expose one cleanly without chunking).

### Model lifecycle

- Stored in **Application Support**, not Caches (Caches can be evicted under storage pressure, and a 250 MB redownload from a coffee shop is bad). Excluded from iCloud backup.
- Pre-download supported from the Settings sheet — preserves the offline-recording promise once installed: zero network calls during a recording session.
- Delete affordance also in Settings, in case the user wants the space back.
- Recording is blocked with a clear message if Whisper is selected but the model isn't downloaded.

---

## Decisions log

| Date | Decision | Why |
|---|---|---|
| 2026-06-08 | Default audio session mode: `.measurement` → `.default` | `.measurement` produced uncomfortably quiet playback with no observable STT win |
| 2026-06-08 | Default AAC bitrate: 64 kbps mono | Voice-grade default; balances size and fidelity for note-taking |
| 2026-06-08 | Default transcription preset: `.transcription` | Maximize accuracy of the stored transcript. Live UX is handled by the streaming override, not the preset choice |
| 2026-06-08 | Streaming session unions `.volatileResults` into user's preset | Get live partials without dragging in `fastResults` (which would reduce accuracy) |
| 2026-06-08 | `AVAudioConverter` left at default quality | Default works; revisit if we see streaming-only accuracy regressions |
| 2026-06-08 | Contextual biasing: empty default | Effect on `SpeechTranscriber` (vs `DictationTranscriber`) is undocumented and untested. Off until we have a test corpus |
| 2026-06-10 | Tier 2 engine: raw `mlx-swift`, not WhisperKit | Keeps the app to one ML runtime (avoiding Core ML + MLX when L1 lands); pays the MLX-on-iOS learning cost on a smaller problem than an LLM; transferable to Parakeet-MLX / Qwen3-ASR follow-ups. Escape valve to WhisperKit behind the same protocol if intractable on iOS |
| 2026-06-10 | Tier 2 default model: `whisper-small.en` | ~250 MB, English-only, good accuracy/footprint balance. `tiny.en` available for low-friction sanity tests |
| 2026-06-10 | Tier 2 first cut: no streaming partials (finalize-only) | Chunked streaming for Whisper is its own design problem; ship the no-partials path first, revisit if dogfood UX demands it |
| 2026-06-10 | Tier 2 buffer strategy: in-memory PCM during recording | Simpler than a scratch WAV; fine for notes up to ~30 min on iPhone 15 Pro Max. Revisit trigger captured in [#1](https://github.com/AlteredCraft/relay-notes/issues/1) |
| 2026-06-10 | `TranscriptionOptions` becomes a sum type (`.apple` / `.whisperMLX`) | Two engines with different parameter sets; sum is type-safe with no nullable fields and matches `TranscriptionEngine` selection in `Tunings` |
| 2026-06-10 | T1.1 split into T1.1a (mlx-swift "hello on device") + T1.1b (Whisper transcript) | Research surfaced that `mlx-swift-examples` has no Whisper reference (issue #146 closed unanswered); the actual reference is `ml-explore/mlx-examples` Python — a port, not a copy-paste. T1.1a derisks the SPM dep + Metal-on-device link in one evening before investing in the multi-day port |
| 2026-06-10 | T1.1b smoke-test model: `whisper-tiny.en` (not `small.en`) | `small.en` at FP16 likely needs the `increased-memory-limit` entitlement; free-tier sideload provisioning profiles may strip it. `tiny.en` (~75 MB) fits under the default budget. `small.en` stays the T1.2 production target, gated on entitlement-on-free-tier validation |
| 2026-06-10 | Default model promoted to `whisper-small.en` | After T1.1's tiny.en run succeeded, swapped in small.en (481 MB FP16 safetensors) and re-ran the same smoke. Process did not get killed by jetsam — entitlement empirically *not* required for whisper-small.en on iPhone 15 Pro Max. Accuracy delta on `ls_test.flac`: tiny.en said "goods sold openly, shorted the burden" (nonsense); small.en said "good soul openly shouldered the burden" (the correct phrase). Cost: encoder 60→419 ms, total 491→1772 ms — ~3.6× slower but ~3.4× real-time on a 6 s clip, comfortable for finalize-only UX |
| 2026-06-10 | Dropped `tiny.en` support entirely (T1.2a) | With `small.en` validated as the production default and no user-facing variant picker planned for v1, `tiny.en` was dead code (one persisted `whisperModelVariant` value never read, one `WhisperModelVariant` enum case never reached, fallback wiring nobody would hit). Deleted the enum, the `Tunings.whisperModelVariant` knob, and the `WhisperMLXOptions` struct's variant + language fields (both English-only-build dead-weight). If a second variant ever returns, re-adding the enum is cheap |
| 2026-06-10 | Whisper assets parametrized by `WhisperModelLocation` (T1.2a) | New `nonisolated enum` with `.bundled` (Bundle lookup, dev) and `.directory(URL)` (filesystem, T1.2b's download path). Refactor was mechanical — `ModelDimensions.loadFromBundle()` → `load(from:)`, same for `WhisperModel`; `WhisperTokenizer.init()` → `init(location:)`; `WhisperAudio.{melFilters,logMelSpectrogram}` gained `from:` (no default — every call site declares its location). T1.2b's `WhisperModelStore` will inject `.directory(applicationSupportURL)` so the recorder uses downloaded weights; bundled stays for dev iteration |

---

## Open questions

- Does setting `converter.sampleRateConverterQuality = .max` change the final streaming transcript at all?
- Does `contextualStrings[.general]` actually bias `SpeechTranscriber` (vs only `DictationTranscriber`)? Need a structured comparison on proper-noun-heavy speech.
- How much does buffer size (4096 → 1024 or 8192) move latency-of-first-partial vs accuracy?
- Should a future "re-transcribe with cloud" action live in `NoteDetailView`? Would lean on the existing file-based `transcribe(_:options:)`.

---

## How to test changes here

1. Pick a representative ~30 s recording (yours, ideally already on the phone).
2. Change one knob in the Tuning sheet.
3. Record the same content. Diff transcripts.
4. Add a row to the table at the top of [notes.md § V1.1 accuracy tuning](./notes.md#v11-accuracy-tuning) — that's where per-knob empirical outcomes live. *This doc* explains the dials; *that section* records what we found by turning them.
