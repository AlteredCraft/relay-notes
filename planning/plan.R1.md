---
title: R1 — Note Revision History (versioned, immutable-rooted) — Design & Implementation Plan
date: 2026-06-15
status: complete
audience: an engineer/agent executing the Note model refactor
---

# R1 — Note revision history: design & implementation plan

> [!done] R1 complete (2026-06-16). R1.0–R1.2 shipped to `main` and device-validated; R1.3 (the
> `#if DEBUG` history browser) was **dropped** in favor of a re-runnable WER benchmark — **GH issue
> #17**. See §1 and the R1.3 entry in §8 for the rationale. The rest of this doc is the as-built record.

This document is a **self-contained handoff** for R1 — replacing the `Note` model's three
ad-hoc text slots (`transcript` / `originalTranscript` / `cleanedTranscript`) with a single
**immutable-rooted, append-only revision history**. It assumes you have **not** seen the
prior session. Read §0–§4 before writing code; §5–§9 are the working reference.

Companion docs (read for the *why*):
- `CLAUDE.md` (repo root) — conventions, build/test, SwiftData/persistence notes, the provider spine.
- `planning/notes.md` — the build plan; the enrichment roadmap (categorize, summarize…) is what
  makes a *general* revision model pay off rather than over-engineer.
- `planning/plan.L2.md` — the cleanup pass that produced `cleanedTranscript` (the third slot
  this refactor unifies).
- `CHANGE_LOG.md` — `2026-06-11` (edit/revert, the 2-state baseline) and `2026-06-14` (L2 cleanup).

Related: GH **issue #5** (CLOSED — "Allow editing the text of a transcription", which introduced
the deliberate *two-state* `originalTranscript` baseline R1 now supersedes); GH **issue #4**
(keep raw audio as a debug/tuning asset — R1 leans into this: audio is the immutable source and
re-transcription is an in-note revision, not a clone).

> [!important] The thesis R1 is built on
> The **machine transcription is immutable** — it is the first revision's content and is never
> mutated in place. Every later transformation (hand-edit, LLM cleanup, re-transcription, future
> categorize/summarize) is an **append-only `Revision`** layered on top, with provenance and a
> pointer to what it derived from. The displayed text is an **active-revision pointer**, not a
> mutable field. This collapses N special-cased field-pairs into one model and fixes a class of
> cross-state bugs that already exists (§2).

> [!note] Clean cutover — no data migration (decision 2026-06-15, Sam, Q5)
> Existing notes are **discarded**, not migrated. Before installing the first R1 build, **delete
> the app from the device** — that wipes the SwiftData store *and* the audio in Documents
> together, so the new schema is the only one that ever exists. This removes the entire
> backfill/transition machinery the earlier draft carried. There is **no migration code** and the
> new `Note` carries **no legacy fields**. (Installing R1 *over* the old store would fail to open
> the incompatible schema on launch — delete-then-install avoids that.)

---

## 0. How to work this plan

- **Stages are sequential** (R1.0 → R1.4) and each is independently shippable + committable.
- Each stage = write Swift → `xcodebuild build` (simulator compile-check) → run the test suite.
  Nothing in R1 touches MLX, so the whole refactor is **simulator-validatable** — no device gate
  except the usual end-to-end smoke once it's wired.
- **Tests first** (global convention): the revision-mutation helpers are *pure functions over
  data*. Write their tests before the implementation; they're simulator-safe and run on every
  `xcodebuild test`.
- **Commit per stage** with a `CHANGE_LOG.md` entry and the `Co-Authored-By` trailer. Update §1.
- **Cutover is manual and one-time:** delete the app from the device before installing R1.0 (the
  store + audio are wiped together). No in-app reset code.

---

## 1. Status snapshot

| Stage | What | State |
|---|---|---|
| **R1.0** | `Revision` `@Model` + `RevisionKind` + `Note` `[Revision]` relationship + `activeRevisionID` + seeding initializer + pure mutation helpers (append transcription/edit/cleanup, move active, revert). Added **alongside** the legacy slots (strangler-fig, see note below). | ✅ **DONE — simulator-validated 2026-06-15.** `Relay Notes/Models/Revision.swift` + `Note` additions + `RevisionTests` (13, incl. the §2 stale-cleanup bug now unrepresentable + a SwiftData round-trip). `Revision` auto-registers via the relationship (no explicit schema change needed; the round-trip test confirms it). Full suite green (199 tests). |
| **R1.1** | `RevisionComparisonView` — consolidate `ReTranscribeOutcomeSheet` + `CleanupOutcomeSheet` into one before/after view (no diff engine). *Pulled forward from R1.2 — the only remaining decoupled piece (see note below).* | ✅ **DONE — simulator-validated 2026-06-15.** `Relay Notes/Views/RevisionComparisonView.swift` (generic `title` + two `Side`s + primary/secondary `Action`); both `NoteDetailView` sheets now use it; the two private structs deleted. Pure refactor, no data-flow change. Full suite green (199 tests). |
| **R1.2** | **The atomic consumer + presentation flip** → **minimal prod UI** (decision: don't preserve the old UI). `NoteDetailView` now shows the active revision + moves it forward (Clean up / Edit / Revert); `NotesListView` row + search read `displayText`; `Cleaner.clean` cleans the active text. Legacy slots + helpers **removed**; `isEdited`/`isCleaned` redefined off `activeRevision`; legacy `NoteTests` replaced with `displayTitle` coverage. **Re-transcribe + the raw/cleaned toggle left prod** (re-transcribe → R1.3 debug). | ✅ **DONE — simulator-validated 2026-06-15.** 201 tests green. |
| **R1.3** | ~~Debug revision-history surface (`#if DEBUG`)~~ | 🚫 **DROPPED (2026-06-16, Sam).** The revision model already gives prod its value (revert + compare); a debug *browser* over the history (activate/delete/compare/re-transcribe) added UI complication for a debugging-only need. The real need — measuring how alternate engines transcribe our audio — is better served by a re-runnable **WER benchmark** than a throwaway in-app screen. Tracked in **GH issue #17**. **R1 is complete at R1.2.** |

> [!note] Sequencing refinement (2026-06-15, during R1.1) — the consumer rewire is coupled
> The old R1.1 ("rewire consumers") can't be done independently of the old R1.3 ("prod
> `NoteDetailView`"). During the strangler-fig window the **legacy slots are the source of truth**:
> the detail view still reads/writes `note.transcript` directly. Migrating any "current text"
> reader (`NotesListView`, `Cleaner.clean`, the detail view's own presentation) to `displayText`
> while the writer still mutates legacy slots would **diverge** — a legacy edit updates
> `note.transcript` but not the active revision. So all reads + writes of note text must flip
> **together** (now R1.2). The genuinely decoupled work — the `RevisionComparisonView` refactor —
> was pulled forward as R1.1. `RecorderViewModel`/`SampleNotes` need no change: the seeding `init`
> already gives them a transcription revision.

> [!note] Sequencing refinement (2026-06-15, during R1.0) — strangler-fig, not big-bang
> R1.0 cannot literally ship "a `Note` with no legacy fields": `NoteDetailView` and the recorder
> still read `transcript`/`isEdited`/`cleanedTranscript`, so removing the slots now would break the
> build and the per-stage "build clean; suite green" gate. So the revision system is added
> **alongside** the legacy slots (the existing `init` now *also* seeds the first `.transcription`
> revision). Consumers migrate off the slots in R1.1; `NoteDetailView` is the last, in R1.3, where
> the slots + their helpers are finally deleted and `isEdited`/`isCleaned` are redefined off
> `activeRevision` (the only two names that collide between old and new during the transition). The
> clean-cutover decision (§3.3, no data migration) is unaffected — this is purely code sequencing.

---

## 2. The decision — what & why

**Model a `Note` as an immutable audio source + an append-only, time-ordered list of
`Revision`s, with a single `activeRevisionID` selecting what the prod UI shows.** Each revision
carries a `kind`, its full resulting `text`, a provenance `modelLabel`, and a nullable
`derivedFromID` (the revision it was produced from; `nil` ⇒ rooted at the audio). Why this shape:

1. **The current design accretes.** Three text slots today, each with bespoke
   accept/revert/toggle logic in `NoteDetailView`. Every enrichment stage on the roadmap
   (categorize, summarize, title-gen…) adds another slot and another pairwise interaction. A
   revision list is O(1) model growth for O(N) feature growth.

2. **It fixes a real bug, not just a smell.** `NoteDetailView.onReplace` (re-transcribe → Replace)
   overwrites `note.transcript` and clears `originalTranscript` but **does not clear
   `cleanedTranscript`**. So: clean a note → re-transcribe → Replace, and the detail view still
   shows the *old* cleaned text by default (`showingCleaned` is true), now derived from a
   transcript that no longer exists. Nobody designed that — it fell out of three independent
   slots not knowing about each other. Append-only + `derivedFromID` makes this state
   unrepresentable (the stale cleanup simply isn't active, and is visibly derived from a
   non-current transcription).

3. **It makes "immutable transcription" true.** Today `transcript` is mutated in place by edits
   and by Replace; the "canonical raw" is a moving target with a 2-state backup. R1 makes the
   machine transcription a revision whose content is never rewritten.

4. **The prod/debug split falls out for free** — same data, two surfaces (§5.4). No scattered
   bespoke state.

> [!note] This reverses a deliberate prior decision — on purpose
> Issue #5 chose *two states by design — original and current — not a full history*. That was
> correct **then**: editing was the only transformation. The enrichment roadmap (≥3 transformation
> kinds) changes the calculus. Recording the reversal here so future-you knows it was
> reconsidered, not forgotten. Decision owner: Sam.

### What R1 is explicitly NOT doing (scope fence)

- **No data migration.** Clean cutover — existing notes are discarded (delete app + reinstall).
  The new `Note` has no legacy fields and there is no backfill (Q5).
- **No diff engine.** Comparison is side-by-side before/after only (§5.3). A cleanup is a
  wholesale rewrite; word-level diff would be visual noise.
- **No derivation-tree UI.** The history is rendered as a flat timeline. `derivedFromID` is stored
  for correctness/provenance but is not traversed as a tree in v1 (§3.2).
- **No clone-on-re-transcribe.** Re-transcription is a new `.transcription` revision *within the
  same note* (audio stays singular and immutable). Note-level cloning is deferred (Q4) — it would
  reintroduce the audio-ownership / refcount problem `deleteWithAudio` doesn't have today.
- **No cross-transcription edit migration.** Switching the active transcription does not re-apply
  prior edits/cleanups to it; they remain in history, rooted at the transcription they came from.

---

## 3. Load-bearing findings & constraints — READ FIRST

### 3.1 The provider-abstraction spine is untouched

R1 is a *persistence/model* refactor. `Transcriber`, `LanguageModel`, `Cleaner`, `ReTranscriber`
keep their protocols and behavior. What changes is the **write target**: instead of assigning
`note.transcript = …` / `note.cleanedTranscript = …`, callers append a `Revision` and (where
appropriate) move `activeRevisionID`. The `Outcome` structs (`Cleaner.Outcome`,
`ReTranscriber.Outcome`) already carry exactly the data a revision needs (`text` + `modelLabel`).

### 3.2 Flat list, not a tree — store `derivedFromID`, render a timeline

Once a note holds transcription-revisions **A** and **B**, derivations technically form a tree
(`A → edit(A) → cleanup(A)`, `B → cleanup(B)`). **Do not model or render a tree in v1.** Store
the history as a flat, time-ordered list; give each revision a nullable `derivedFromID`:

- `.transcription` → `derivedFromID = nil` (rooted at audio).
- `.edit` → `derivedFromID =` the revision being edited (active at edit time).
- `.cleanup` → `derivedFromID =` the revision it cleaned (active at clean time).

This satisfies every stated need — compare any two, pick active, show provenance — while keeping
SwiftData modeling and queries trivial. A tree *visualization* can be added later from
`derivedFromID` with no remodeling.

### 3.3 Clean cutover — no migration code

This is **not** a SwiftData migration at all (Q5). The new `Note`/`Revision` schema ships as if
greenfield; the old store is destroyed out-of-band by deleting the app before installing R1.0.
Consequences for the build:

- The new `Note` carries **no** `transcript`/`originalTranscript`/`cleanedTranscript`/
  `transcriptionModel`/`cleanupModel` — those fields are simply gone, not deprecated.
- No `revisions(fromLegacy:)` backfill, no idempotent launch trigger, no transition window.
- `SampleNotes` (the only "pre-existing data" that survives) is rewritten to seed revisions
  directly (§6), so previews/tests have the new shape from the first line.

### 3.4 Ordering and the active pointer

SwiftData to-many relationships are **unordered**. Order the history by `createdAt` at read time
(add an explicit `Int index` only if same-millisecond collisions become real). Store
**`activeRevisionID: UUID`** on `Note` (not a second relationship) to avoid a dangling to-one on
delete; resolve `activeRevision` against the array. **Invariant:** a note **always** has ≥1
revision and a valid `activeRevisionID` — guaranteed by the seeding initializer (§5.1) and
preserved by every op (§5.2).

### 3.5 `deleteWithAudio` and cascade

`Note.deleteWithAudio(in:)` stays the canonical delete. Add `@Relationship(deleteRule: .cascade)`
so deleting a note removes its revisions; the audio-file removal is unchanged (audio is on `Note`,
one per note, immutable). Deleting an *individual revision* (debug surface, R1.4) must never delete
the last revision and must re-point `activeRevisionID` if it pointed at the deleted one.

---

## 4. Reference materials

- Current model: `Relay Notes/Models/Note.swift` — the three slots + their helpers
  (`applyEditedTranscript`, `revertTranscript`, `applyCleanup`, `clearCleanup`, `isEdited`,
  `isCleaned`). These become revision ops; the slots are deleted.
- Current consumers writing the slots:
  - `Relay Notes/Recording/RecorderViewModel.swift:157` — builds the initial `Note` (→ seed
    `.transcription` revision via the new initializer).
  - `Relay Notes/Enrichment/Cleaner.swift` — produces `Cleaner.Outcome` (→ `.cleanup` revision).
  - `Relay Notes/Recording/ReTranscriber.swift` — produces `ReTranscriber.Outcome` (→ new
    `.transcription` revision).
  - `Relay Notes/Models/SampleNotes.swift:25` — seeded notes (give each a single `.transcription`).
  - `Relay Notes/Views/NoteDetailView.swift` — all presentation + the two before/after sheets.
- Schema registration: `Relay Notes/Relay_NotesApp.swift:17` (`.modelContainer(for: Note.self)`),
  plus the `inMemory: true` previews in `ContentView.swift:85`, `SettingsView.swift:214`,
  `NotesListView.swift:99`.
- Existing tests to extend/replace: `Relay NotesTests/NoteTests.swift` (16 tests over the slot
  helpers + insert/fetch round-trips) — the template for the revision-op tests. The slot-specific
  cases are replaced by revision-op cases.

---

## 5. Architecture specifics

### 5.1 The model (R1.0)

```swift
enum RevisionKind: String, Codable {
    case transcription   // machine STT — the initial auto pass AND any re-transcribe
    case edit            // user hand-edit
    case cleanup         // LLM enrichment (L2)
    // future: categorization, summary, title, translation…
}

@Model final class Revision {
    var id: UUID
    var createdAt: Date
    var kind: RevisionKind
    var text: String
    /// Provenance: "Apple Speech", "Whisper (small.en)", "Gemma 4 E2B (MLX 4-bit)".
    /// `nil` for `.edit` (the user is the author).
    var modelLabel: String?
    /// The revision this was produced from. `nil` ⇒ rooted at the audio (every
    /// `.transcription`). Stored for provenance + staleness; not traversed as a tree in v1.
    var derivedFromID: UUID?
    var note: Note?      // inverse

    init(id: UUID = UUID(), createdAt: Date = .now, kind: RevisionKind,
         text: String, modelLabel: String? = nil, derivedFromID: UUID? = nil) { … }
}

@Model final class Note {
    var id: UUID
    var createdAt: Date
    var audioFilename: String                    // immutable source
    var title: String?                           // stays on Note, not a revision (Q3)
    @Relationship(deleteRule: .cascade, inverse: \Revision.note)
    var revisions: [Revision]
    var activeRevisionID: UUID                    // what prod UI shows / shares

    /// Seeding initializer — the only way to make a Note, so the ≥1-revision +
    /// valid-active invariant holds by construction. Builds the first
    /// `.transcription` revision and points `activeRevisionID` at it.
    convenience init(audioFilename: String, transcription: String, modelLabel: String?) { … }
}
```

The five legacy slots are **gone** (clean cutover). `title` stays a top-level field (Q3 — a title
is not a transformation of the transcript; revisit only if auto-title becomes an enrichment kind).

### 5.2 Computed accessors + mutation ops (R1.0, pure, tested first)

On `Note` (replacing the slot helpers):

- `var activeRevision: Revision` — resolve `activeRevisionID` against `revisions` (invariant:
  always present).
- `var orderedRevisions: [Revision]` — `revisions.sorted { $0.createdAt < $1.createdAt }`.
- `var latestTranscription: Revision?` — last `.transcription` by order (the re-transcribe target /
  "original" for prod compare).
- `var displayText: String` — `activeRevision.text` (what `NoteDetailView`/`ShareLink` read).
- `func appendTranscription(text:modelLabel:) -> Revision` — append `.transcription`
  (`derivedFromID = nil`); set active to it.
- `func appendEdit(text:) -> Revision?` — **Q1 resolved:** if `text` equals the parent
  (`activeRevision`) text, **re-activate the parent** and return `nil` (no redundant revision —
  this is the "edit back to original returns to pristine" behavior). Otherwise append `.edit`
  (`derivedFromID = activeRevision.id`) and set active.
- `func appendCleanup(text:modelLabel:) -> Revision` — append `.cleanup`
  (`derivedFromID = activeRevision.id`); set active.
- `func revert()` — **Q1 resolved:** move `activeRevisionID` to `activeRevision.derivedFromID`
  (re-activate the parent), or to `latestTranscription` if the active revision is rooted. No
  deletion — revert is a pointer move; history is preserved.
- `var isEdited: Bool` — `activeRevision.kind == .edit`.
- `var isCleaned: Bool` — `activeRevision.kind == .cleanup` (or "a `.cleanup` exists in history" if
  the indicator should persist while viewing the raw — decide with the R1.3 UI; keep current UX).

All pure data ops — **write `NoteTests` cases first**, mirroring the existing 16 (minus the
slot-specific ones).

### 5.3 Comparison view (R1.2)

`ReTranscribeOutcomeSheet` and `CleanupOutcomeSheet` in `NoteDetailView.swift` are the **same**
before/after view with different labels. Collapse into:

```swift
struct RevisionComparisonView: View {
    let left: RevisionDisplay    // (label, text) — e.g. "Current — Apple Speech"
    let right: RevisionDisplay   // e.g. "New — Whisper (small.en)"
    let primaryAction: (title, () -> Void)    // Replace / Accept
    let secondaryAction: (title, () -> Void)  // Keep original / Discard
}
```

Serves the accept/decline flows **and** "compare two transcription-revisions" (debug) with no new
UI. No diff — two `Text` blocks, `textSelection(.enabled)`, as today.

### 5.4 Prod vs debug surfaces (R1.3 / R1.4) — one model, two views

- **Prod** (`NoteDetailView`): shows `note.displayText` (active revision). Affordances:
  *Edit* (→ `appendEdit`), *Clean up* (→ `appendCleanup`), *Revert* (→ `revert`),
  *Compare with original* (active vs `latestTranscription` via `RevisionComparisonView`).
  Indicators (`Edited`, `Cleaned with …`) read off `activeRevision`.
- **Debug** (`#if DEBUG`, Q2): the full `orderedRevisions` timeline — each row shows kind,
  `modelLabel`, `createdAt`, `derivedFromID` lineage, and "make active" / "delete" / "compare".
  Re-transcribe appends a `.transcription`; you can sit two transcription-revisions side by side.
  This is the home for the issue-#4 "audio as a debug/tuning asset" workflow. Compiled out of
  prod sideloads; revisit a runtime toggle only if dogfooding wants it in a release build.

---

## 6. Codebase integration (the write-path changes)

- `RecorderViewModel.finalize` (`:157`) — `Note(audioFilename:transcription:modelLabel:)` seeds the
  first `.transcription` revision and sets `activeRevisionID` (the new convenience init, §5.1).
- `Cleaner` consumer (`NoteDetailView.onAccept`) — `note.appendCleanup(text: outcome.cleaned,
  modelLabel: outcome.modelLabel)` instead of `applyCleanup`.
- `ReTranscriber` consumer (`NoteDetailView.onReplace`) — `note.appendTranscription(text:
  outcome.transcript, modelLabel: outcome.modelLabel)`. **This is where the old stale-cleanup bug
  dies**: the new transcription becomes active; the prior cleanup stays in history, plainly derived
  from a now-inactive transcription.
- `SampleNotes` (`:25`) — give each seeded note one `.transcription` revision via the new init.
- `Relay_NotesApp` (`:17`) — `.modelContainer(for: Note.self)` still works (SwiftData discovers
  `Revision` through the relationship). Update the 3 `inMemory` preview containers similarly.

---

## 7. The dev loop

1. Write/extend `NoteTests` for the new op (simulator-safe, no MLX).
2. `xcodebuild build … | xcbeautify` (compile-check).
3. `xcodebuild test … | xcbeautify` (the suite; new file wired via
   `ruby scripts/add_test_file.rb` if added).
4. End-to-end smoke on device once wired (record → edit → clean → re-transcribe), then commit +
   `CHANGE_LOG.md` entry. (No migration to validate — clean cutover.)

---

## 8. Remaining work — stage by stage

### R1.0 — Model + pure ops ✅ DONE (simulator-validated 2026-06-15)
`Revision.swift` (+ `RevisionKind`) and the `Note` revision relationship + `activeRevisionID` +
seeding init + §5.2 ops, added alongside the legacy slots (strangler-fig). `RevisionTests` (13):
seeding/invariant, `append*` + `derivedFromID` lineage, Q1 (edit-back re-activates parent; revert
is a pointer move), the §2 stale-cleanup bug proven unrepresentable, and a SwiftData round-trip.
`Revision` registers via the relationship (round-trip test confirms — no explicit schema change).
Full suite green (199 tests).

### R1.1 — `RevisionComparisonView` ✅ DONE (simulator-validated 2026-06-15)
`Relay Notes/Views/RevisionComparisonView.swift` — generic `title` + two `Side`s + primary/secondary
`Action`. Both `NoteDetailView` sheets reworked onto it; the two private sheet structs deleted. Pure
refactor, no data-flow change (accept/decline flows unchanged). Pulled forward from R1.2 as the only
decoupled remaining work. Full suite green (199 tests).

### R1.2 — Minimal prod UI flip ✅ DONE (simulator-validated 2026-06-15)
Decision (Sam): **don't preserve the old UI** — replace with a minimal prod UI where the user views
the note (active revision) and moves it forward (Clean up / Edit / Revert). Done in one change:
`NoteDetailView` rewritten (active-revision body; provenance label off `activeRevision.kind`;
Edit → `appendEdit`, Clean up → `appendCleanup`, Revert → `revert`; cleanup before/after via
`RevisionComparisonView`); `NotesListView` row + search read `displayText`; `Cleaner.clean` cleans
`note.displayText`. Legacy slots (`transcript`/`originalTranscript`/`cleanedTranscript`/
`transcriptionModel`/`cleanupModel`) + helpers deleted; the seeding `init` keeps the
`transcript:`/`transcriptionModel:` *param names* (so `RecorderViewModel`/`SampleNotes` are
untouched) but stores no slots. `isEdited`/`isCleaned` redefined off `activeRevision`. Legacy
`NoteTests` replaced with `displayTitle` tests; added `Cleaner` cleans-active-text test +
`isEdited/isCleaned` revision test. **Dropped from prod:** re-transcribe (→ R1.3 debug; `reTranscriber`
still injected into `NotesListView`, reserved) and the raw/cleaned toggle. The §2 stale-cleanup
class is gone (re-transcribe now appends a fresh active transcription). 201 tests green.

### R1.3 — Debug revision-history surface (`#if DEBUG`) — 🚫 DROPPED (2026-06-16, Sam)
**R1 is complete at R1.2** (on `main`, device-validated 2026-06-16). R1.3 was going to be a
`#if DEBUG` browser over a note's full revision history (timeline, activate/delete/compare,
re-transcribe). It was dropped before implementation.

**Why dropped:** the revision model already delivers its prod value — revert and compare-with-original
work without a history browser. R1.3 would have added non-trivial UI (selection-mode compare, per-row
delete, a re-transcribe menu) purely to serve a *debugging* need. Discussing the UI surfaced that the
underlying need is **"measure how alternate engines transcribe our audio,"** which is better met by a
durable, re-runnable **WER benchmark** than a throwaway in-app screen — especially since a tripped-up
transcript bounds what cleanup can recover (see [[cleanup-model-next]] memory). That work is tracked
separately in **GH issue #17** (transcriber-only WER over a fixed corpus; post-cleanup WER out of scope).

**Consequence for the code:** `NotesListView.reTranscriber` (reserved "for the R1.3 surface") now has
**no consumer**. Leave it or remove it as part of #17 — the WER harness is the natural home for the
file-based re-transcribe path (`Transcriber.transcribe`), not the prod list view. `RevisionComparisonView`
stays in prod use (the cleanup before/after sheet). No model op was added (the planned invariant-preserving
`deleteRevision` is unneeded — no UI deletes individual revisions).

---

## 9. Conventions & gotchas checklist

- [ ] **Cutover:** delete the app from the device before installing R1.0 (wipes store + audio).
- [ ] **Invariant:** every `Note` has ≥1 revision and a valid `activeRevisionID`. Enforced by the
      seeding init; re-checked after any delete.
- [ ] **Append-only:** never mutate a revision's `text` in place. Transformations append.
- [ ] **`derivedFromID` set correctly** for `.edit`/`.cleanup`; `nil` for `.transcription`.
- [ ] **Q1:** edit-back-to-parent re-activates the parent (no redundant revision); revert is a
      pointer move, not a delete.
- [ ] **Ordering** by `createdAt`; add explicit `index` only if collisions appear.
- [ ] **`deleteWithAudio` cascade** removes revisions; individual-revision delete re-points active.
- [ ] **Debug surface** behind `#if DEBUG`.
- [ ] **User-facing errors stay generic** (Projects/CLAUDE.md) — unchanged.
- [ ] **`CHANGE_LOG.md`** entry per stage; note the issue-#5 reversal.
- [ ] **Tests first**, simulator-safe (no MLX in the model layer).

---

## 10. Resolved decisions

All open questions resolved 2026-06-15 (Sam):

- **Q1 — edit-back-to-original / revert.** Re-activate the parent revision (no redundant edit
  revision). Revert is a pointer move. (§5.2.)
- **Q2 — debug surface gating.** `#if DEBUG` (compiled out of prod sideloads). Runtime toggle only
  if a release build later needs it. (§5.4.)
- **Q3 — title provenance.** `Note.title` stays a top-level field, not a revision kind. Revisit
  only if auto-title becomes an enrichment stage. (§5.1.)
- **Q4 — note-level clone.** Out of scope; not a concern for now. Re-transcription stays an in-note
  `.transcription` revision. (§2 scope fence.)
- **Q5 — migration.** None. Clean cutover — existing notes discarded by deleting the app before
  installing R1.0; the new `Note` carries no legacy fields and there is no backfill. (§3.3.)
