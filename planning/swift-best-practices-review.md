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

## Recommended larger refactors (needs Xcode verification)

Real improvements, but each needs a compiler in the loop. Ranked by value.

1. **Dedup the three model sections** — `Views/WhisperModelSection.swift`,
   `ParakeetModelSection.swift`, `CleanupModelSection.swift` are ~90% identical
   (the `.missing`/`.downloading`/`.ready`/`.failed` status switch, the
   download/delete actions, the delete-confirmation alert). A shared
   download-section view collapses ~270 lines to ~100. This is view composition,
   not a provider-abstraction change, so it's CLAUDE.md-safe. *(If extracted to
   its own file, wire it into the pbxproj.)*
2. **`Transcription/Parakeet/ParakeetDecoder.swift` — `fatalError` on the
   per-decode-step hot path** (`joint_net[2] as? Linear`, inside
   `callAsFunction`). The invariant is fixed at `init`; resolve the final
   `Linear` once into a typed stored property to remove a per-step cast + crash
   path.
3. **Extract `engineRow(title:subtitle:isSelected:isEnabled:onSelect:)` in
   `Views/SettingsView.swift`** — the Whisper/Parakeet/Apple engine `Button`
   rows are byte-for-byte the same shape.
4. **KV-cache `typealias`** in `Transcription/WhisperModel.swift` +
   `WhisperDecoding.swift` — name the
   `((MLXArray, MLXArray)?, (MLXArray, MLXArray)?)` tuple so the `.0.0.shape[1]`
   index chains become legible. Pure readability, but ~8 mechanical edit sites
   where a typo breaks the build.
5. **`Transcription/Parakeet/ParakeetConfig.swift` — drop dead
   `Encodable`/`encode(to:)`.** Config types are decode-only; this removes the
   most fragile block in the file. Verify nothing encodes them first.
6. **`presetLabel` / `presetID` → `switch`** (`Views/RecorderView.swift`,
   `Recording/Tunings.swift`) *if* `SpeechTranscriber.Preset` is an enum — gains
   compiler exhaustiveness so a new preset can't silently persist as
   `"transcription"`. Confirm the type first; if it's a struct of static lets,
   the if-chain is unavoidable and should get a comment saying so.

---

## Lower-priority polish

- **Doc copy mismatch:** "~2.7 GB" (in `Cleaner.swift` / `MLXLanguageModel.swift`
  comments) vs "about 3.4 GB" (the `CleanupModelSection` UI string) for the
  cleanup model. Reconcile before open-sourcing.
- **Magic-number constants** that would read better as named `private static let`s:
  `duration - 0.05` (`AudioPlayer.tick`), the two distinct `1e-5` epsilons in
  `ParakeetAudio` (log-floor vs normalization guard — same value, different
  meaning), `+ 1024` resampler headroom (`LiveAudioEngine`), `0.001` timestamp
  nudge (`Note.nextTimestamp`).
- **`NotesListView.deleteNotes(at:)`** indexes `filteredNotes` by `IndexSet`
  offset — correct today (matches the `ForEach` source), but a comment asserting
  that invariant guards against silent off-by-one deletes if the rendered list
  source ever diverges.
- **`RecorderViewModel.stopAndTranscribe()`** repeats the
  `updatesTask`/`session`/`currentAudioURL` teardown across three paths; cancel
  once up-front after `engine.stop()` to drop two copies.
- **`ModelStores`** has six `init` overloads as a test seam — a single defaulted
  init or a `static func forTesting(...)` factory would be more pragmatic and
  avoid silently spinning up real filesystem-backed stores for unspecified slots.
- **Error-type naming inconsistency:** `WhisperModelError` (free-standing) vs
  nested `WhisperAudio.Error` / `WhisperTokenizer.Error` (which force
  `Swift.Error` qualification). Pick the free-standing form for consistency.
- **`NoteDetailView` / `RecorderView`** each carry their own seconds→`m:ss`
  formatter; consolidate to one shared helper.
- **`DownloadableModelStore`**: the `-1` sentinel in
  `unexpectedHTTPStatus(-1)` reads as a real HTTP status in logs — prefer a
  distinct `.internalInconsistency`-style case.

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
