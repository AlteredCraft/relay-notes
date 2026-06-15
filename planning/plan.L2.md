---
title: L2 — On-Device Cleanup Model (LLM enrichment) — Implementation Plan & Handoff
date: 2026-06-14
status: living
audience: an engineer/agent building the on-device cleanup harness
---

# L2 — On-device cleanup model: implementation plan & handoff

This document is a **self-contained handoff** for L2 — the first LLM-enrichment stage: take a
messy on-device transcript and clean it up with a **local LLM**, and **prove on real hardware**
whether that mitigates speech-to-text errors well enough that chasing a better *transcriber*
stops mattering. It assumes you have **not** seen the prior session. Read §0–§4 before writing
code; §5–§9 are the working reference.

Companion docs (read for the *why*):
- `CLAUDE.md` (repo root) — conventions, build/test, MLX gotchas, the provider spine.
- `planning/notes.md` — the build plan. The **Current POV callout** + "**Next — the cleanup
  model**" roadmap + **Appendix A** are L2's charter; this doc is the execution detail.
- `planning/transcription-tuning.md` — decisions log (the 2026-06-14 "Apple permanent default;
  accuracy from cleanup" row is L2's premise).
- `planning/plan.T2.md` — the prior on-device-MLX handoff; reuse its patterns wholesale
  (smoke harness shape, device logging, memory instrumentation, incremental load, dev loops).
- `CHANGE_LOG.md` — the `2026-06-14` "Plan recalibrated" entry.

Related: GH **issue #10** (Gemma 4 E2B via LiteRT-LM — a *different runtime* track, not this).
Prior art: **Google AI Edge Eloquent** (on-device Gemma ASR + on-device LLM cleanup) — the shape
L2 validates and the bar to beat.

> [!important] The thesis L2 tests
> Apple Speech is the **permanent default** transcriber; we are **not** chasing transcription
> accuracy. The bet is that a local LLM cleanup pass *mitigates* STT errors and unlocks more
> (de-filler, structure, categorize). L2's job is to **prove or disprove that on the iPhone 15
> Pro Max** — with the runtime and quantization we'd actually ship — before building any real UX.

---

## 0. How to work this plan

- **Stages are sequential** (L2.0 → L2.4) but small. L2.0 is the inference wiring (the "L1
  spike" folded in so this doc is executable end-to-end); L2.1–L2.3 are the harness + the
  go/no-go; L2.4 is conditional app wiring.
- Each stage = write Swift → `xcodebuild build` (simulator, compile-check) → for anything
  touching MLX, **device-validate via `LLMCleanupSmoke`** (the simulator cannot run MLX, §3.2).
- The **ground-truth gate** is L2.3: a head-to-head run over real Apple-Speech transcripts that
  produces a recorded verdict ("does cleanup mitigate STT errors, and which model earns it?").
- Keep `LLMCleanupSmoke.swift` as the device harness; add a section per stage (mirror
  `ParakeetSmoke`).
- **Commit per stage** with a `CHANGE_LOG.md` entry (non-optional repo convention) and the
  `Co-Authored-By` trailer. Update §1 as you go.

---

## 1. Status snapshot

| Stage | What | State |
|---|---|---|
| **L2.0** | Inference wiring — `LanguageModel` protocol + `MLXLanguageModel` (via `mlx-swift-lm`), generate on device | ✅ **DONE — device-validated 2026-06-14 (iPhone 15 Pro Max).** Gemma 4 E2B non-QAT (`gemma-4-e2b-it-4bit`) loads (3.4 s, resident floor 2.67 GB) + generates **excellent** cleanup; ~23 tok/s (approx); **peak 3.02 GB** — just under the ~3 GB no-entitlement ceiling on a *tiny* sample (longer notes likely need the entitlement). Free-tier build accepted the entitlement (§10 Q3 resolved). QAT build doesn't load (§4). Deps: mlx-swift-lm 3.31.3 + swift-huggingface 0.9.0 + swift-transformers 1.3.3 + hand-rolled bridge (§3.1/§6). |
| **L2.1** | `CleanupPrompt` (centralized) + `clean()` + `LLMCleanupSmoke` skeleton | ✅ **done with L2.0** — `CleanupPrompt.swift` + `clean()` + a 1-sample `LLMCleanupSmoke` shipped + device-validated. Remaining polish (carry into L2.3): pure metric-helper unit tests; **precise tok/s** (stream token counts vs the current word-count approximation). |
| **L2.4** | **In-app "Clean up" action** in `NoteDetailView` (pulled forward — see re-sequencing note) | ✅ **DONE — device-validated 2026-06-14 (iPhone 15 Pro Max).** Cleanup works end-to-end on a real note. Centralized model management in the Tuning sheet (`CleanupModelStore` + `CleanupModelSection`, same `DownloadableModelStore` infra as Whisper/Parakeet); "Clean up" gates on model presence with a Tuning deep-link; before/after **Accept/Decline**; non-destructive (`Note.cleanedTranscript`, raw preserved). See §6. |
| **L2.2** | ~~Fixtures → `cleanup_fixtures.json`~~ | ⊘ **superseded by in-app dogfooding** (see note) — real notes cleaned in-app *are* the corpus + the quality judgment. Revive only if a deterministic fixed-corpus check is wanted later. |
| **L2.3** | Head-to-head model verdict (Gemma vs Qwen vs cloud ceiling) | ⊘ **deferred, not lost** — `LLMCleanupSmoke` (repo-id path) still sweeps candidates when we want the formal A/B / a model picker. Dogfooding is the primary signal now. |

> [!note] Re-sequencing (2026-06-14, post-L2.0)
> L2.0 proved on-device cleanup *works* with strong quality, retiring the "harness-first,
> UI-last" caution (its whole point was de-risking the unknown). We **pulled L2.4 forward** and
> made the real in-app feature the evaluation vehicle — dogfooding real notes is a better quality
> signal than curated fixtures (L2.2) and yields the transcripts for free. The L2.3 harness stays
> available for a rigorous model A/B; it's deferred, not deleted. Decision owner: Sam.

Prereqs from elsewhere: the `increased-memory-limit` entitlement — **resolved at L2.0** (free-tier
sideload accepts it, §10 Q3).

---

## 2. The decision — what & why

**Build the cleanup pass as an on-device MLX LLM behind a new `LanguageModel` protocol, and
prove it with a device smoke harness before any UI.** Why this shape:

- **MLX, not LiteRT, for the quick path.** The spine is already MLX (`mlx-swift` for Whisper +
  Parakeet); the primary cleanup candidate is **Gemma 4 E2B via MLX** (the family proven for this
  exact task in Google AI Edge Eloquent), with **Qwen 3.5 4B via MLX** as the fallback. Testing
  MLX models is *both* the quick path (reuse the spine) and apples-to-apples with what we'd ship.
  We run Gemma 4 E2B through its **MLX** build (`mlx-community`, via `mlx-swift-examples`) — *not*
  the **LiteRT-LM** package (the ~0.8 GB text-only build that sparked this), which is the separate,
  heavier issue #10 track. (Caveat — Eloquent runs Gemma on LiteRT, so MLX arch support is the
  gating risk; see §3.1.)
- **Use `mlx-swift-examples`, don't hand-port.** Whisper/Parakeet were hand-ports because no
  Swift ASR-LLM reference existed. For *text* LLMs, `mlx-swift-examples` (`MLXLLM` /
  `MLXLMCommon`) already implements Qwen3/Gemma/Llama/Phi architectures + HF download +
  tokenizer chat-templates. L2.0 is "add the SPM dep + call the API," a fraction of a port.
- **Harness-first, UI-last.** Cleanup quality is the unknown; UX is not. A `#if DEBUG` smoke
  that prints before/after + metrics answers the thesis for ~zero UI cost (same play as
  `MLXSmoke`/`ParakeetSmoke`). Only wire app UX (L2.4) *after* a model passes.

> [!warning] Why Ollama-on-Mac is NOT the test (the apples-to-apples point)
> Pulling `gemma4:e2b` via Ollama differs from the phone on **all three axes at once**:
> **runtime** (llama.cpp vs MLX/LiteRT), **build/quant** (7.2 GB Q4_K_M *multimodal* vs the
> ~0.8–2.5 GB text-only mobile build), and **hardware** (a Mac's GPU/RAM vs an 8 GB phone).
> It's a useful *quality smell-test* ("is this family smart enough?") but tells you nothing
> about on-device footprint/latency. The only valid test runs on the 15 Pro Max via the
> shipping runtime over real transcripts — i.e. `LLMCleanupSmoke`.

---

## 3. Load-bearing findings & constraints — READ FIRST

### 3.1 Inference engine: `mlx-swift-lm` (was `mlx-swift-examples`), with fallbacks

> [!note] L2.0a verified (2026-06-14) — gating risk RESOLVED, **GO on the MLX path**
> The package **moved**: the LLM implementations that used to live in `mlx-swift-examples`
> are now in **`github.com/ml-explore/mlx-swift-lm`** — add *that* package. Latest tag **3.31.3**;
> products **`MLXLLM` + `MLXLMCommon`**; it depends on mlx-swift `.upToNextMinor(from: "0.31.3")`,
> i.e. `>= 0.31.3, < 0.32` — **compatible** with the project's current mlx-swift pin
> (`>= 0.31.0`, already resolved to 0.31.4), so adding it just tightens the floor to 0.31.3.
> **Both arches are implemented** (verified against the `3.31.3` source tree):
> `Libraries/MLXLLM/Models/Gemma4.swift` + `Gemma4Text.swift` and `Qwen35.swift`, with
> `LLMTypeRegistry` entries `gemma4`/`gemma4_text` and `qwen3_5`/`qwen3_5_text`. So the
> Eloquent-style MLX path stands — **no need** to drop to LiteRT/#10 *or* the Qwen fallback on
> arch grounds. Repo-id + footprint corrections are in §4.

- **Primary:** add the **`mlx-swift-lm`** Swift package and use its LLM libraries
  (`MLXLLM` + `MLXLMCommon`). The model factory (`LLMModelFactory.shared`) loads a model
  **container** from an HF repo id (downloads weights into the app container) and exposes a
  token-streaming `generate` API; it picks the arch from the repo's `config.json` `model_type`
  (so any repo whose type is registered loads — no preset needed) and applies the model's
  **chat template** via the tokenizer (swift-transformers under the hood).
  *Confirm exact symbol names at integration — this package evolves (the T2 port hit
  mlx-swift 0.25.3→0.31.4 drift); pinned to **3.31.3**, read its current LLM example sources.*
- **Fallbacks (only if the primary churns):** `LocalLLMClient` (MIT, GGUF+MLX, *experimental*),
  or raw `mlx-swift` + a hand-rolled tokenizer/sampler (the Whisper/Parakeet style — far more
  work; avoid unless forced).
- **Transitive deps:** `mlx-swift-lm` pulls **swift-syntax** (`from: 600.0.0`, for the
  `MLXHuggingFace` macros) and `swift-docc-plugin`. Linking only `MLXLLM` + `MLXLMCommon`
  shouldn't *build* the macro target, but SPM resolves swift-syntax into the graph — expect a
  slower first resolve. Build-time watch-item, not a blocker.
- **License hygiene:** Gemma 4 cards report **Apache 2.0**; Qwen has been Apache 2.0 — verify per
  model before shipping (a `# config required, fail-fast` concern).

### 3.2 MLX cannot run on the iOS Simulator

Same hard rule as T1/T2. Any `MLXArray` op crashes the simulator (insufficient `MTLGPUFamily`).
- MLX-touching **app code** compiles on the simulator but only *runs* on device.
- MLX-touching **tests** must be gated `#if !targetEnvironment(simulator)`.
- Numerics/behavior validate through `LLMCleanupSmoke` (DEBUG button → device → read logs).
Keep all the **pure** parts (prompt construction, fixture parsing, length-ratio checks, the
results table) simulator-safe and unit-tested normally.

### 3.3 Memory & the entitlement — the real gate for L2

A 3–4B model at 4-bit is ~2.5 GB resident, **above** the ~3 GB no-entitlement jetsam ceiling once
KV-cache + activations are added — so L2 is expected to **need
`com.apple.developer.kernel.increased-memory-limit`** (Whisper/Parakeet did not; an LLM does).
notes.md expects it to work on the free-tier sideload; **confirm on-device at L2.0** — if it
doesn't, that's the trigger for V1.4 (paid program), and an explicit finding.
- The 15 Pro Max budget: `maxRecommendedWorkingSetSize` ≈ 5.73 GB (from Appendix C).
- **Load models one at a time.** Reuse the **single-live-MLX-engine** insight from T2.4: when
  the harness sweeps candidates, fully release model A before loading model B (and
  `MLX.GPU.clearCache()` between) so two LLMs are never co-resident. The transcriber and the
  cleanup model also shouldn't be co-resident — but cleanup runs *after* finalize, so sequence them.
- Reuse the **memory instrumentation** from `MLXSmoke`/`ParakeetSmoke`: `MLX.Memory.snapshot()`
  (active/cache/peak) + `phys_footprint` via `task_info`. Record peak per candidate.

### 3.4 Device logging must be durable (`os.Logger`, not `print`)

Copy the `ParakeetSmoke` convention: `os.Logger.notice(... privacy: .public)`, subsystem
`alteredcraft.Relay-Notes`, category `LLMCleanupSmoke`. Read in the Xcode console or Console.app
untethered. Log each fixture's *raw* text and metrics **before** the generate call so an OOM
mid-generation still leaves a trail.

### 3.5 The provider-abstraction spine is load-bearing — preserve it

Cleanup sits behind a new `LanguageModel` protocol exactly as transcription sits behind
`Transcriber`. Adding a model = a factory arm + a settings entry, never a special-case. The
prompt + (later) taxonomy are **centralized** so swapping providers never changes behavior
(notes.md: "the model picks from `allowed`, it never invents categories"). See §6.

### 3.6 `nonisolated protocol`

`LanguageModel` is isolation-neutral, so it **must** be declared `nonisolated protocol`
(project default is `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; an unannotated protocol leaks
`@MainActor` onto conformers — the exact trap documented in CLAUDE.md and the 2026-06-11 change
log). `Transcriber`/`TranscriptionSession` are the precedent. The MLX-backed conformer is an `actor`.

---

## 4. Reference materials

- **Inference:** `mlx-swift-lm` (Apple/ml-explore, formerly `mlx-swift-examples`) — `MLXLLM`,
  `MLXLMCommon`. Pinned **3.31.3**; read its current LLM example for the load/generate API.
- **Models (HF `mlx-community` 4-bit — repo ids verified at L2.0a, 2026-06-14):**

  | Model (MLX 4-bit) | repo (verified) | License | Role |
  |---|---|---|---|
  | **Gemma 4 E2B** (non-QAT) | `mlx-community/gemma-4-e2b-it-4bit` | Apache 2.0 (verify) | **primary** — proven family in Edge Eloquent; the library's registered preset (loads) |
  | **Qwen 3.5 4B** | `mlx-community/Qwen3.5-4B-4bit` | Apache 2.0 (verify) | **fallback** — pure-text, standard arch; the clean comparison point |

  **Verified-id corrections + the QAT load failure (device, 2026-06-14):**
  - **The `-qat-4bit` build does NOT load in MLXLLM 3.31.3.** `mlx-community/gemma-4-E2B-it-qat-4bit`
    omits `k_proj`/`v_proj` weights on Gemma 4's **KV-cache-sharing layers** (15–34 of 35; later
    layers reuse earlier layers' KV). MLXLLM's `Gemma4Attention` handles KV-sharing at *runtime*
    (a `sharedKV` path) but still declares a `kProj` Linear for **every** layer, so weight-loading
    throws `keyNotFound` at layer 15. The **non-QAT `gemma-4-e2b-it-4bit`** materializes `k_proj`
    on all 35 layers (verified via its `model.safetensors.index.json`) → it loads, and it's the
    build the library actually validated (`LLMRegistry.gemma4_e2b_it_4bit`). **So the plan's
    "prefer `-qat-4bit`" is overridden by tooling: use the standard 4-bit build.** (Both are
    multimodal configs, `model_type: gemma4`; `Gemma4Model` runs the text tower. The download is a
    single ~4.3 GB `model.safetensors` — footprint watch-item the smoke quantifies.)
  - **Qwen fallback id is `Qwen3.5-4B-4bit`, not `…-MLX-4bit`** (the latter doesn't exist on HF;
    config: `model_type: qwen3_5`, 4-bit/group-64, pure text — no KV-sharing/multimodal quirks).
  - **Arch support confirmed (§3.1)** — both `gemma4`/`gemma4_text` and `qwen3_5`/`qwen3_5_text`
    are in `LLMTypeRegistry` at `3.31.3`; the Qwen fallback is a *quality/footprint/robustness*
    hedge, not an arch hedge.

- **Our smoke precedent:** `Relay Notes/Transcription/Whisper/MLXSmoke.swift` and
  `…/Parakeet/ParakeetSmoke.swift` — copy the structure (DEBUG, `os.Logger`, `PeakMemorySampler`,
  a `run()` that sequences sections, the Settings debug button).
- **Prior art:** Google AI Edge Eloquent — on-device Gemma ASR + LLM cleanup, optional cloud
  Gemini, transform modes (Key points / Formal / Short / Long). Validates the shape; informs
  later L3 (categorize) and the cloud opt-in (L4).

---

## 5. Architecture specifics

### 5.1 The `LanguageModel` protocol (L2.0)

```swift
// Enrichment/LanguageModel.swift
nonisolated protocol LanguageModel: Sendable {
    /// Clean a raw transcript: de-filler, fix run-ons/punctuation, light structure.
    /// MUST preserve meaning and content — no summarizing, no invented facts.
    func clean(_ raw: String) async throws -> String
    // L3 adds: func categorize(_ note: String, into allowed: [String]) async throws -> Categorization
}
```

Keep `categorize` out of L2 (that's L3) but design the protocol so adding it is additive.

### 5.2 `MLXLanguageModel` (L2.0)

```swift
// Enrichment/MLXLanguageModel.swift
actor MLXLanguageModel: LanguageModel {
    // holds a loaded model container (from mlx-swift-examples), keyed by repo id
    // load: factory.loadContainer(repoId) → cache; generate: stream tokens, return full string
    nonisolated let modelDescription: String  // provenance, e.g. "Qwen3-4B-4bit (MLX)"
}
```

- One model live at a time (§3.3). Expose a way to **evict** (drop the container +
  `MLX.GPU.clearCache()`) so the harness can sweep candidates.
- `clean(_:)` = build the prompt (§5.3) → apply the model's chat template → generate →
  return the assistant text, trimmed. Generation is off the main actor; later it can stream into
  the view (notes.md "generation off the main thread, streaming tokens into the view").

### 5.3 The centralized cleanup prompt (L2.1)

One source of truth — `Enrichment/CleanupPrompt.swift`. First cut (tune per the §10 prompt
caveat; chat templates differ per model and are applied by the tokenizer, **not** hand-baked):

```
You are a transcript cleanup assistant. The text below is a raw speech-to-text transcript of a
spoken voice note. It may contain filler words, false starts, run-on sentences, missing
punctuation, and recognition errors where a word was misheard.

Clean it up:
- Remove fillers and false starts (um, uh, "like", repeated words, self-corrections).
- Add punctuation, capitalization, and paragraph breaks.
- Fix obvious misrecognitions ONLY when the intended word is clear from context.
- Preserve the speaker's meaning, wording, and all information.
  Do NOT summarize, shorten, add facts, or change the substance.
- If a word is garbled and you can't infer it, leave it or mark it [unclear].

Output only the cleaned transcript, nothing else.

Transcript:
"""
{transcript}
"""
```

### 5.4 `LLMCleanupSmoke` (L2.1) — the harness

`#if DEBUG`, device-only, triggered from the Settings debug section. Shape (mirror
`ParakeetSmoke`):

```
for each candidate model (repo id):
    load container; log load time + resident footprint
    for each fixture transcript:
        t0; cleaned = clean(raw); dt
        log: ── fixture <label> · model <id> ──
             RAW:     <raw>
             CLEAN:   <cleaned>
             metrics: tok/s, total ms, length ratio (clean/raw words), peak phys_footprint
    evict model; MLX.GPU.clearCache()
log a final per-model summary table
```

Outputs answer both questions at once: **quality** (read RAW→CLEAN pairs) and **viability**
(tok/s, load, peak footprint vs the ~5.73 GB budget / entitlement). Keep the metric math
(length ratio, averages) in a pure, simulator-tested helper.

### 5.5 Fixtures (L2.2)

`Resources/cleanup_fixtures.json` — an array of `{ label, rawTranscript }`, **real Apple-Speech
output** captured during V1.3 dogfooding. Curate ~5–8 spanning the failure modes that matter:
- a long rambly note (run-ons, self-corrections),
- a noisy-environment note (more misrecognitions),
- a jargon/proper-noun note (`AlteredCraft`, `MLX`, names) — the hardest for cleanup,
- a short crisp note (cleanup should barely touch it — a "do no harm" check),
- a numbers/dates note (formatting).
Bundled flat at the `.app` root (file-system-synchronized group flattens — see CLAUDE.md);
load via `Bundle.main`. Deterministic + shareable beats pulling live from SwiftData.

### 5.6 Evaluation rubric (L2.3)

Quality is subjective → primary signal is **eyeball the pairs**, but pin objective guards:
- **Length ratio** in a sane band (~0.6–1.1× words): a big drop = summarizing (a failure mode,
  not cleanup); a big rise = padding/hallucination.
- **No new facts** (manual per fixture) — the cardinal sin; an LLM "improving" a note by
  inventing detail is worse than a raw transcript.
- **Errors actually fixed** (manual) — did it repair the misrecognitions the raw had?
- **Viability**: tok/s (is a 5-min note's cleanup acceptable?), load time, peak footprint /
  entitlement.
- **Ceiling**: run the same fixtures through a frontier cloud model (or paste to Claude). The
  **gap** = what on-device costs you. If on-device ≈ ceiling on these notes, the thesis holds.

Record the verdict in a results table in this doc (§8 L2.3), a `CHANGE_LOG.md` entry, and a
`transcription-tuning.md`-style decisions row — including **which model (if any) earns the
cleanup slot** and whether the entitlement was needed.

---

## 6. Codebase integration (the Enrichment spine)

New `Relay Notes/Enrichment/` group (auto-included — file-system-synchronized):

1. ✅ **`Enrichment/LanguageModel.swift`** — the `nonisolated protocol` (§5.1) + `LanguageModelError`.
2. ✅ **`Enrichment/HuggingFaceBridge.swift`** — hand-rolled `Downloader` + `TokenizerLoader`
   conformances (the §3.1 decision) so we use `mlx-swift-lm`'s HF download/tokenizer path
   *without* `MLXHuggingFace`/swift-syntax. Transcribed from upstream's macro expansions; matched
   to swift-huggingface 0.9.0 / swift-transformers 1.3.3.
3. ✅ **`Enrichment/MLXLanguageModel.swift`** — the `actor` conformer (§5.2); `loadContainerIfNeeded`
   + `clean()` via `ChatSession` + `evict()`.
4. ✅ **`Enrichment/CleanupPrompt.swift`** — the centralized prompt (§5.3).
5. ✅ **`Enrichment/LLMCleanupSmoke.swift`** — `#if DEBUG` device harness (§5.4); L2.0 section
   (1 inline sample) shipped.
6. ☐ **`Relay Notes/Resources/cleanup_fixtures.json`** — fixtures (§5.5) — L2.2.
7. ✅ **`SettingsView.swift`** — `#if DEBUG` "Run cleanup smoke (console)" button beside the
   existing MLX/Parakeet smoke buttons.
8. **(L2.4, conditional)** `NoteDetailView.swift` — a "Clean up" action that runs `clean()` on
   the note's transcript and shows cleaned-vs-raw. **Non-destructive**: keep the raw transcript;
   store the cleaned text in a *new* `Note` field (e.g. `cleanedTranscript: String?`) — a small
   additive SwiftData change, no migration pain. (Don't overwrite `transcript`.)

**Dependencies (added in Xcode):** `mlx-swift-lm` 3.31.3 (`MLXLLM` + `MLXLMCommon`) +
`huggingface/swift-huggingface` 0.9.0 (`HuggingFace`) + `huggingface/swift-transformers` 1.3.3
(`Tokenizers`). The latter two are what `mlx-swift-lm` externalized (§3.1); we link them directly
and bridge by hand rather than pull `MLXHuggingFace`/swift-syntax. New **test files** still need
`ruby scripts/add_test_file.rb <File>.swift`.

---

## 7. The dev loops

**Build (compile-check, simulator):**
```sh
xcodebuild build -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | xcbeautify
```
**Test (simulator; MLX tests gated out):**
```sh
xcodebuild test -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -only-testing:"Relay NotesTests/<Suite>" 2>&1 | xcbeautify
```
New test files: `ruby scripts/add_test_file.rb <File>.swift`. New app source files auto-include.

**Device-validate (the only way to run MLX):** build/run to the iPhone 15 Pro Max from Xcode
(renew free-tier signing if the 7-day window lapsed; **add the increased-memory-limit
entitlement** for L2), then **Tuning sheet → Debug → "Run cleanup smoke (console)"**. Read via
Xcode console or Console.app (subsystem `alteredcraft.Relay-Notes`, category `LLMCleanupSmoke`).
First run downloads the candidate model(s) from HF into the app container.

**MLX memory API** (confirmed in T2): `MLX.GPU.set(cacheLimit:)`, `MLX.GPU.clearCache()`,
`MLX.Memory.snapshot()`, `MLX.GPU.resetPeakMemory()`; `phys_footprint` helper already in the
smoke files — lift it.

---

## 8. Remaining work — stage by stage

For each: **goal · do · validate · gotchas · done-when.**

### L2.0 — Inference wiring (the "L1 spike")
- **Do:** add `mlx-swift-examples`; **confirm it implements the Gemma 4 arch** (§3.1 — the gating
  risk, do this first); `Enrichment/LanguageModel.swift` (protocol) + `MLXLanguageModel.swift`
  (load a container from a repo id, generate, evict). Add the `increased-memory-limit` entitlement.
- **Validate:** device — generate from a trivial prompt with **Gemma 4 E2B**; log tok/s, load time,
  **peak footprint**, and a FITS/NEEDS-entitlement verdict vs the ~5.73 GB budget.
- **Gotchas:** §3.1 arch support (Gemma 4 is new — if unsupported, fall back to Qwen 3.5 4B, or
  LiteRT/#10) + API drift; §3.3 memory/entitlement; §3.2 device-only; §3.6 `nonisolated protocol`.
  Chat template comes from the tokenizer — don't bake it.
- **Done-when:** a prompt generates coherent text on the 15 Pro Max; metrics recorded here + CHANGE_LOG.

### L2.1 — Cleanup prompt + harness skeleton
- **Do:** `CleanupPrompt.swift` (§5.3); implement `clean(_:)`; `LLMCleanupSmoke.swift` (§5.4)
  with 1–2 inline sample transcripts to start; Settings debug button. Pure metric helpers
  (length ratio, averages) unit-tested on the simulator.
- **Validate:** device — one transcript cleans; before/after + metrics print.
- **Done-when:** smoke prints a RAW→CLEAN pair with metrics for Gemma 4 E2B; build + sim tests green.

### L2.2 — Fixtures
- **Do:** capture ~5–8 real Apple-Speech transcripts during dogfooding → `cleanup_fixtures.json`
  (§5.5); load in the harness; loop over all fixtures.
- **Validate:** harness runs the full fixture set on device for one model.
- **Done-when:** the bundled fixtures drive the smoke; the set spans the §5.5 failure modes.

### L2.3 — Head-to-head + verdict (THE GATE)
- **Do:** sweep candidates (Gemma 4 E2B primary + Qwen 3.5 4B fallback), evicting between
  (§3.3). Run the cloud ceiling on the same fixtures. Fill the results table below.
- **Validate / record:**

  | Model | Quality (eyeball) | Errors fixed? | New facts? | tok/s | Load | Peak GB | Entitlement | Verdict |
  |---|---|---|---|---|---|---|---|---|
  | Gemma 4 E2B | | | | | | | | |
  | Qwen 3.5 4B | | | | | | | | |
  | cloud (ceiling) | — | | | — | — | — | — | reference |

- **Done-when:** a recorded answer to *"does on-device cleanup mitigate STT errors enough to
  make raw-transcriber accuracy a non-issue, and which model earns the slot?"* — in this table,
  a CHANGE_LOG entry, and a decisions-log row. **If yes → proceed to L2.4 / L3. If no →** record
  why (too slow, too lossy, hallucinates, needs a bigger model than fits) and the pivot (cloud
  cleanup L4? smaller-scope cleanup? revisit transcriber default?).

### L2.4 — (conditional) minimal in-app cleanup
- **Do:** only if L2.3 passes. A "Clean up" action in `NoteDetailView` behind `LanguageModel`,
  **non-destructive** (new `cleanedTranscript: String?` field; raw preserved); stream tokens into
  the view; generic-actionable error if the model is missing/OOMs (CLAUDE.md error rule).
- **Done-when:** on the phone, a saved note's transcript can be cleaned and shown cleaned-vs-raw;
  raw is never lost.

---

## 9. Conventions & gotchas checklist

- [ ] **MLX is device-only** — gate tests `#if !targetEnvironment(simulator)`; validate via `LLMCleanupSmoke`.
- [ ] **One LLM live at a time** — evict + `clearCache()` between candidates / vs the transcriber (§3.3).
- [ ] **`increased-memory-limit` entitlement** added + its necessity recorded (the L2 memory gate, §3.3).
- [ ] **`mlx-swift-examples`, not a hand-port**; pin the version; chat template via the tokenizer (§3.1).
- [ ] **`nonisolated protocol`** for `LanguageModel`; conformer is an `actor` (§3.6).
- [ ] **Centralized prompt** (`CleanupPrompt`) — one source; no per-call prompt drift (§3.5/§5.3).
- [ ] **`os.Logger.notice(... privacy: .public)`** for device output; log raw + metrics *before* generate (§3.4).
- [ ] **Non-destructive cleanup** — keep `transcript`; cleaned text in a new field (§6 / L2.4).
- [ ] **New app files auto-included**; new **test files** need `ruby scripts/add_test_file.rb`.
- [ ] **User-facing errors generic + actionable**; detail to logs only (Projects/CLAUDE.md).
- [ ] **No default fallbacks for required config** (e.g. model repo id) — fail fast (Projects/CLAUDE.md).
- [ ] **Append a `CHANGE_LOG.md` entry per stage**; update §1 + the L2.3 results table.

---

## 10. Open questions / pending decisions

1. ~~**Candidate set / exact repo ids + arch support**~~ — **RESOLVED at L2.0a (2026-06-14).**
   Gemma 4 *and* Qwen 3.5 arches are both implemented in `mlx-swift-lm` (the renamed package),
   tag `3.31.3` (§3.1). Verified repo ids: primary `mlx-community/gemma-4-E2B-it-qat-4bit`
   (multimodal config, text tower loaded — footprint watch-item), fallback
   `mlx-community/Qwen3.5-4B-4bit` (§4). The Qwen fallback is now a quality/footprint hedge, not
   an arch hedge. Remaining real unknown is **footprint + quality on device** (L2.0 / L2.3).
2. **`mlx-swift-examples` vs fallbacks** — default to the package; only drop to `LocalLLMClient`
   / raw `mlx-swift` if it churns (§3.1).
3. ~~**Entitlement on free-tier sideload**~~ — **RESOLVED at L2.0 (2026-06-14).** The free Apple ID
   tier **accepts** `com.apple.developer.kernel.increased-memory-limit`: the device build signed,
   installed, and ran with it — no V1.4 trigger. Nuance: the L2.0 tiny sample peaked **3.02 GB**,
   just *under* the ~3 GB no-entitlement ceiling, so it didn't strictly need the entitlement; a
   real multi-minute note (larger KV cache) likely will, so it stays. **Re-measure peak on a long
   fixture at L2.2/L2.3** to confirm where real notes land vs the ceiling.
4. **Prompt tuning depth** — the prompt is a variable, and chat templates differ per family. How
   much per-model prompt tuning is fair before declaring a model "good enough"? Hold the prompt
   *fixed* across the head-to-head for comparability; tune only after a winner is chosen.
5. **Evaluation rigor** — L2 uses eyeball + objective guards + a manual cloud ceiling. An
   automated LLM-judge (cloud model scoring on-device output) is a later upgrade if needed.
6. **Streaming** — cleanup can stream tokens into the view (UX win) but the harness runs one-shot;
   defer streaming to L2.4.
7. **Where cleaned text lives** — `cleanedTranscript: String?` on `Note` (additive) is the L2.4
   plan; the raw `transcript` stays canonical. Confirm no SwiftData migration surprises.
8. **Unify the smoke buttons** — `MLXSmoke`/`ParakeetSmoke`/`LLMCleanupSmoke` are accruing in the
   Debug section; a small "device harness" picker could tidy them later (cosmetic).
