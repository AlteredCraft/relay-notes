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
> container with no Xcode toolchain; rounds **3**, **B**, and **4** were authored
> *and* build+test verified locally (iPhone 17 Pro simulator, 61-test suite green).
> Item **A** is additionally **device-validated** (iPhone 15 Pro Max,
> `ParakeetSmoke.run()` both gates green). Earlier rounds are merged to `main`;
> round 4 (F, G, docstrings) **and A** are build+test green (A also device-green) in
> the working tree, pending commit. **The review backlog is now empty** — every
> actionable item is applied; only the cosmetic H/I and the declined `preset → switch`
> were intentionally skipped.

---

## Remaining work — start here

**Nothing open — every actionable item is applied.** F, G, and the docstring pass
landed 2026-06-19 (build + test verified); **A** landed 2026-06-20 (device
`ParakeetSmoke` verified on the iPhone 15 Pro Max). See *Applied* below for each.

- [x] **A — `ParakeetDecoder` per-step `fatalError` → `[UnaryLayer]` joint head**
  (2026-06-20, device-validated). Resolved *better* than the original "stored
  `Linear`" sketch: retyping `joint_net` `[Module]` → `[UnaryLayer]` lets the joint
  apply `joint_net[2](…)` directly (no cast, no `fatalError`) with **provably zero**
  parameter-tree change — MLXNN's `build(value:)` reflects the array by runtime
  value, so keying is independent of the static element type. → *Larger refactors*.

**Not doing** (recorded for completeness): **H** (error-type naming) and **I** (time
formatter) — low value; **preset → `switch`** — declined (`SpeechTranscriber.Preset`
is a struct, not a closed enum). **Gate for any code change:** `xcodebuild build` +
`xcodebuild test` (simulator suite); MLX-touching changes additionally need a device
`ParakeetSmoke` / `MLXSmoke` run.

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

### Applied — round 4: F, G, docstrings (committed 2026-06-19, **build + test verified**)

Closes the last simulator-validatable items. `xcodebuild build` + the 61-test
suite, both green on the iPhone 17 Pro simulator. No behavior change on any path.

| Item | Files | Resolution |
|---|---|---|
| **G — `ModelStores` six-`init` seam** | `Transcription/ModelStores.swift` | Six overloads → **one `nil`-defaulted init** (`whisper:parakeet:cleanup:`, each `?? Real…Store()`). Every call site (production `ModelStores()` + the test combos) is unchanged. `nil` defaults sidestep the original "can't call the `@MainActor` store init from a nonisolated default-arg context" problem — the `??` fallbacks run in the `@MainActor` init body. |
| **F — `stopAndTranscribe()` teardown dedup** | `Recording/RecorderViewModel.swift` | The two identical light teardowns (guard-else + success) collapse into one up-front block: cancel `updatesTask`, capture `let session = self.session`, nil the stored `session`/`currentAudioURL`, then `finish()`/`cancel()` on the **local**. State is already `.finalizing`, so cancelling the partials loop early is a no-op. Catch paths now `await session.cancel()` on the local (the only work `cleanupAfterFailure()` did that wasn't already done up-front), so behavior is preserved without that heavier helper. |
| **Docstring coverage** | `ModelStores.swift`, `RecorderViewModel.swift`, `TranscriberFactory.swift`, `Transcriber.swift`, `AppleSpeechTranscriber.swift` | Backfilled `///` on the **transcriber entry-point spine + recording view model** — the model-store registry, the recording state machine + its public methods, the `Transcriber`/`TranscriptionSession` protocols (incl. the load-bearing two-method `Transcriber` rationale CLAUDE.md flags), the factory resolution entry point, and Apple Speech (was 0%, the default engine). **Targeted, not metric-chased:** the remaining low %s on these files are private DI storage, obvious `init`s, function-body locals, and protocol-conformance re-docs — documenting those is the filler the goal explicitly forbids. The CodeRabbit denominator is narrower than a naive symbol count (PR #19's files read 18–39% by a raw count but CodeRabbit reported 50%), so these land well above the raw numbers. |

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

### Applied — formerly deferred (needed a compiler / device in the loop)

- ~~**`ParakeetDecoder.swift` — `fatalError` on the per-decode-step hot path**~~ —
  **APPLIED (A, 2026-06-20, device-validated on the iPhone 15 Pro Max).** The
  original sketch (resolve the final `Linear` into a stored property) was *rejected*
  as the wrong fix: a second `Linear`-typed stored property would alias `joint_net[2]`,
  adding a duplicate parameter key (`joint.finalLinear.*`) that breaks `verify: .all`
  / save round-trips — trading a crash path for a latent loading bug. **Instead:**
  retype `let joint_net: [Module]` → `[UnaryLayer]` (all three slots — `ReLU`,
  `ParakeetIdentity`, `Linear` — already conform), so `callAsFunction` applies the
  trailing Linear as `joint_net[2](activated)` directly — no cast, no `fatalError`.
  **Why this is safe (the part that needed verifying):** MLXNN keys array children
  by *runtime value*, not static type — `ModuleValue.build(value:)` casts the array
  to `[Any]` and inspects each element `as Module`, so `joint.joint_net.0/1/2` is
  derived identically whether the property is `[Module]` or `[UnaryLayer]`. Confirmed
  on device: `ParakeetSmoke.run()` loaded the full model under `verify: .noUnusedKeys`
  (which throws if `joint.joint_net.2.*` goes unconsumed) and **both** gates passed —
  T2.1d decode `substring check = PASS ✅`, T2.1e `chunking check = PASS ✅`, peak
  1345.5 MB (unchanged). Since it's the same `Linear` with the same weights, output
  is numerically identical to the pre-change path.
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

_Items C, D, E, J (round 3) and **F, G (round 4)** above are now **applied**. The rest:_

- ~~**`RecorderViewModel.stopAndTranscribe()`** (F)~~ — **APPLIED (round 4).** The
  local-`session` capture collapsed the two light teardowns into one up-front
  block; catch paths `cancel()` the local. See the round-4 table for the full
  resolution (and why `cleanupAfterFailure()` wasn't needed on the catch path).
- ~~**`ModelStores`** (G)~~ — **APPLIED (round 4)** as the single `nil`-defaulted
  init (not the `forTesting(...)` factory — defaulted is the more idiomatic
  collapse, and every call site already used labeled args). See the round-4 table.
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

> **Status: first pass applied (round 4, 2026-06-19).** Backfilled the transcriber
> entry-point spine + recording view model (`ModelStores`, `RecorderViewModel`,
> `TranscriberFactory`, `Transcriber`, `AppleSpeechTranscriber`). This is a
> *per-PR moving target*, not a one-and-done — each future PR re-measures its own
> changed set, so the durable fix is the standing rule below (every new
> public/internal decl ships with a doc comment). The rest of this section is the
> rationale that guided the pass.

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
