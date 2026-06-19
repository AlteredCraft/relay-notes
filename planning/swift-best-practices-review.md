---
title: Relay Notes - Swift Best-Practices Review
date: 2026-06-19
tags:
  - altered-craft
  - review
status: living
---

# Swift Best-Practices Review

Pre-open-source review of the Swift code against the official
[Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/),
the [core libraries](https://www.swift.org/documentation/core-libraries/), and
idiomatic [standard-library](https://www.swift.org/documentation/standard-library/)
usage. Goal: pragmatic, not overly clever, ready for public eyes.

Reviewed the full source tree (55 files, ~8.8k lines). This doc is the running
record of what was found, what was applied, and what's left. Update it as items
are worked.

> **Build status.** The first pass (surgical + view/config) was authored in a Linux
> container with no Xcode toolchain; rounds **3** and **B** were authored *and*
> build+test verified locally (iPhone 17 Pro simulator, 61-test suite green).
> Everything in the **Applied** sections is now merged to `main` and compiles/tests
> green. Remaining items keep the same gate: `xcodebuild build` + `xcodebuild test`
> before merge — item **A** also needs a device `ParakeetSmoke` run.

---

## Remaining work — start here

Open items only — everything below is **applied** / **declined** / **left-alone**.
Priority order; each links to its detail section further down.

- [ ] **Docstring coverage → ≥80%** (CodeRabbit gate). Comments-only, no build risk.
  Backfill the most-touched API surface; document the non-obvious, **not** filler.
  → *Docstring coverage*.
- [ ] **F — `RecorderViewModel.stopAndTranscribe()` teardown dedup.** Collapse the
  two identical light teardowns via a local `let session` captured *before*
  `session.finish()`. Live recording path → build + recorder tests (ideally device).
  → *Lower-priority polish*.
- [ ] **G — `ModelStores` six-`init` seam → one defaulted init / `forTesting(...)`.**
  Build/test gated (construction is used app-wide + in tests). → *Lower-priority polish*.
- [ ] **A — `ParakeetDecoder` per-step `fatalError` → stored `Linear`** (deferred).
  Needs a device `ParakeetSmoke` run — MLXNN parameter-key derivation is silently
  breakable here. → *Larger refactors → Deferred*.

**Not doing** (recorded for completeness): **H** (error-type naming) and **I** (time
formatter) — low value; **preset → `switch`** — declined (`SpeechTranscriber.Preset`
is a struct, not a closed enum). **Gate for any code change:** `xcodebuild build` +
`xcodebuild test` (simulator suite); **A** additionally needs a device `ParakeetSmoke` run.

---

## Applied (safe, surgical — committed 2026-06-19)

Low-risk changes confident to compile with no happy-path behavior change.

| Fix | File | Why |
|---|---|---|
| `startTimer`/`stopTimer` → `startPolling`/`stopPolling` | `Audio/AudioPlayer.swift` | Names lied — it's a `Task` poll loop (`pollingTask`), not a `Timer`. CLAUDE.md calls out the Task-not-Timer choice explicitly. |
| Removed dead `LanguageModelError.generationFailed(any Error)` | `Enrichment/LanguageModel.swift` | Never thrown or matched anywhere; `MLXLanguageModel.clean` propagates inference errors verbatim. The case advertised a wrapping that never happened. Doc updated to say errors propagate. |
| Two `xa!` → `else if let xa` + `preconditionFailure` on the unreachable tail | `Transcription/WhisperModel.swift` | One diagnostic site instead of two bare force-unwraps in cross-attention cache-miss. |
| Stale doc `loadFromBundle()` → `load(from:)` | `Transcription/WhisperModel.swift` | Referenced a method that doesn't exist. |
| `orderedRevisions.last!` → diagnostic `preconditionFailure` | `Models/Note.swift` | The comment claimed "crash-free" while force-unwrapping; now surfaces a corrupted/migrated store with a message instead of a bare trap. |

### Applied — view/config refactors (committed 2026-06-19)

A second round, taken on after the safe set. Still uncompiled here — same
build gate applies.

| Refactor | Files | Notes |
|---|---|---|
| Dedup the three model-download sections | new `Views/ModelDownloadSection.swift`; `WhisperModelSection`/`ParakeetModelSection`/`CleanupModelSection` now thin wrappers | Shared view typed on the `@Observable` `DownloadableModelStore` base; the wrappers supply only copy + `onDeleted`. `WhisperModelSection.failureMessage` kept (test-referenced); `SettingsView` call sites unchanged. View composition only. |
| Extract `engineRow(_:title:subtitle:isEnabled:)` | `Views/SettingsView.swift` | Collapsed three near-identical engine `Button` rows into one helper. |
| Downgrade Parakeet config chain `Codable` → `Decodable` + delete dead `encode(to:)` | `Transcription/Parakeet/ParakeetConfig.swift` | Configs are decode-only (no `JSONEncoder` anywhere). The custom `ParakeetDecodingConfig.encode(to:)` existed only because `maxSymbols` has no `CodingKeys` case; the whole chain went to `Decodable` since the parent's synthesized `Encodable` required the child's. |

### Applied — round 3 polish (committed 2026-06-19, **build + test verified**)

The first pass actually compiled + tested locally (`xcodebuild build` + the 61-test
suite, both green on the iPhone 17 Pro simulator). No behavior change on any path.

| Item | Files | Resolution |
|---|---|---|
| **C — "GB mismatch"** | `Enrichment/Cleaner.swift`, `Views/NoteDetailView.swift` | **False alarm.** The spec is authoritatively `downloadSizeMB: 3446` (≈3.4 GB on disk; matches the UI copy and the summed `RemoteFile.size`s). The two "~2.7 GB" comments describe *resident memory freed* — a different quantity (Gemma E2B's per-layer-embedding/MatFormer makes RAM < disk). Clarified the comments as "resident memory," **not** forced equal to the download. |
| **D — magic numbers** | `ParakeetAudio.swift`, `AudioPlayer.swift`, `LiveAudioEngine.swift`, `Models/Note.swift` | `ParakeetAudio`'s two same-valued `1e-5`s split into `logMelFloor` (log-finite on silent bins) vs `normEpsilon` (z-score divide guard); `AudioPlayer.endSnapThreshold` (0.05 s), `LiveAudioEngine.resamplerHeadroom` (1024 frames), `Note.tieBreakNudge` (1 ms). Untyped locals to preserve each literal's exact inferred type. |
| **E — `deleteNotes(at:)` invariant** | `Views/NotesListView.swift` | Comment: the `IndexSet` offsets index into `filteredNotes` *because* that's the `ForEach` source; keep them the same array or swipe-delete hits the wrong rows. |
| **J — `-1` HTTP-status sentinel** | `Transcription/DownloadableModelStore.swift` | `unexpectedHTTPStatus(-1)` (the "succeeded with no file" guard) → distinct `CoordinatorError.missingDownloadResult`; no longer masquerades as a real status in logs. Falls through to the generic network-failure arm. |

---

## Deliberately *not* changed

Things the review flagged that are better left alone:

- **Don't unify `userMessage` / `userFacingMessage` / `failureMessage` naming.**
  `ReTranscriber.userMessage`, `Cleaner.userMessage`, and
  `WhisperModelSection.failureMessage` are all referenced by the test target.
  Renaming for cosmetic consistency would churn tests for no real gain.
- **`AudioFormat`'s `nonisolated`, `Tunings.presetID` if-chain, local `var … = nil`.**
  These depend on compiler semantics not verifiable without building
  (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; whether `SpeechTranscriber.Preset`
  is an enum; local-optional initialization rules). Leave until build-checked.
- **ML-layer naming** (`joint_net`, `pos_bias_u`, `qU`/`qV`, snake_case
  `ModelDimensions` fields). Intentional 1:1 mirroring of the upstream
  Python/PyTorch reference, or forced by MLXNN parameter-key derivation. The
  existing justifying comments are the right call; renaming would only obscure
  the port correspondence.

---

## Larger refactors — remaining / declined

Items 1, 3, and 5 from the original list are now **applied** (see above). The
rest:

### Deferred — do with a compiler in the loop

- **`Transcription/Parakeet/ParakeetDecoder.swift` — `fatalError` on the
  per-decode-step hot path** (`joint_net[2] as? Linear`, inside
  `callAsFunction`). Resolving the final `Linear` once into a stored property
  would remove the per-step cast + crash path — but adding a second
  `Linear`-typed property risks MLXNN's parameter-tree key derivation
  (`joint_net`'s own comment warns that property-name-based weight keying here
  is load-bearing and *silently* breakable). Do this with the `ParakeetSmoke`
  device validation in the loop to confirm weights still load.
- ~~**KV-cache `typealias`**~~ — **APPLIED (B, 2026-06-19, build + test verified).**
  Introduced `WhisperKV = (MLXArray, MLXArray)` (one attention's keys/values) and
  `WhisperLayerKVCache = (WhisperKV?, WhisperKV?)` (a decoder block's self+cross
  cache) at the top of `WhisperModel.swift`; substituted all 11 sites across
  `WhisperModel.swift` + `WhisperDecoding.swift`. Pure compile-time substitution
  (identical underlying types — element chains like `kvCache[0].0` are unchanged),
  so the simulator build + 61-test suite fully verify it; no device run needed.

### Declined

- **`presetLabel` / `presetID` → `switch`** — `SpeechTranscriber.Preset` is an
  Equatable **struct** with static factory values (`.transcription`,
  `.progressiveTranscription`, …), not a closed enum, so it can't be `switch`ed
  exhaustively. The `if preset == …` chain with a fallback arm is the correct
  idiom for an open set; a `switch` would gain nothing.

---

## Lower-priority polish

_Items C, D, E, J above are now **applied** (round 3). The rest:_

- **`RecorderViewModel.stopAndTranscribe()`** (F) repeats the
  `updatesTask`/`session`/`currentAudioURL` teardown across the guard-else and
  success paths (the catch path's `cleanupAfterFailure()` is a *heavier*
  teardown — `await session.cancel()` + the feed/interruption/elapsed tasks — and
  stays separate). **Correction to the original note:** you can't "cancel once
  up-front and nil `session`" — the success path calls `try await session.finish()`
  first. The real fix captures a local `let session = self.session`, nils the
  stored property + cancels `updatesTask` immediately after `engine.stop()`, then
  calls `.finish()` on the local. Collapses the two identical light copies into
  one. Touches the live recording path → build + recorder tests (ideally device).
- **`ModelStores`** (G) has six `init` overloads as a test seam — a single
  defaulted init or a `static func forTesting(...)` factory would be more pragmatic
  and avoid silently spinning up real filesystem-backed stores for unspecified
  slots. Build/test gated (construction is used app-wide + in tests).
- **Error-type naming inconsistency** (H) — `WhisperModelError` (free-standing) vs
  nested `WhisperAudio.Error` / `WhisperTokenizer.Error` (which force
  `Swift.Error` qualification). Pick the free-standing form for consistency.
  *Low value — cosmetic churn across the Whisper layer; skip unless doing a
  broader rename.*
- **Time formatter** (I) — **the original framing was stale.** `RecorderView` does
  *not* carry its own formatter; it calls `RecorderViewModel.formatElapsed`
  (`RecorderView.swift:65`). The only duplication is `NoteDetailView`'s private
  `String(format: "%d:%02d", …)`. And the two take *different input types*
  (`Duration` vs an `Int` of seconds), so a shared helper buys ~3 lines for added
  friction. *Skip, or a trivial shared helper at most.*

---

## Docstring coverage (CodeRabbit gate)

CodeRabbit's pre-merge checks (CHILL profile) flagged **docstring coverage at 50%
against an 80% threshold** on PR #19's changed set. It's a *soft warning* — it
didn't block the merge — but it names a real open-source-readiness gap worth
closing deliberately. Context so the number isn't misread:

- PR #19's own *new* declarations were documented (`WhisperKV` /
  `WhisperLayerKVCache`, `CoordinatorError.missingDownloadResult`). The 50%
  reflects **pre-existing undocumented declarations in the touched files**, not
  the changes themselves.
- The check re-measures the **changed files on each PR**, so it's a per-PR moving
  target — backfilling the heavily-touched files is what makes it durably pass.

**Goal:** bring docstring coverage on the public/internal API surface to **≥80%**
as part of the pre-open-source pass. Approach:

- Backfill `///` comments on the most-touched types/methods first (the model
  stores, transcriber/decoder entry points, the view models) rather than chasing
  the metric file-by-file.
- Ensure every *new* public/internal declaration ships with a doc comment, so the
  number trends up rather than down.
- **Don't** add filler to satisfy the percentage — `/// The initializer.` on an
  obvious `init` is noise. Document the non-obvious (invariants, units, isolation,
  ownership), the same bar the model layer already meets (this review calls those
  doc comments "notably good"). A metric-driven pass that lowers signal is a
  regression even if the number goes green.

Build/test impact: none (comments only); no device run needed.

---

## Notes for reviewers

- The **provider abstraction** (everything behind a protocol — `Transcriber`,
  `TranscriptionSession`, `LanguageModel`), **MLX device-only test gating**,
  **`nonisolated protocol`** isolation discipline, and **bundled-asset handling**
  are all load-bearing per CLAUDE.md. None of the items above touch them; keep it
  that way.
- The model layer's doc comments are notably good. The download coordinator's
  lock-guarded continuation hand-off is sound. No correctness bugs were found
  that fire in normal operation — the findings are naming/clarity/pragmatism,
  which is exactly the open-source-readiness goal.
