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

> **Build caveat.** The first pass was done in a Linux container with no Xcode
> toolchain, so nothing below was compiler-verified there. Every applied change
> is happy-path-behavior-preserving, but a full Xcode build + `xcodebuild test`
> is the gate before merging any of it.

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
