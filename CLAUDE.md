# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this app is

iOS SwiftUI voice-notes app. v1 scope is intentionally narrow: tap → speak → on-device transcript saved. All LLM cleanup/categorization is deferred. Target device is iPhone 15 Pro Max; v1 ships to a personal device via Developer Mode sideload (free Apple ID tier — paid Apple Developer Program enrollment is deferred until on-device MLX inference is validated; see `planning/notes.md` V1.3 / V1.4).

The authoritative docs are:
- `planning/notes.md` — full build plan, scope decisions, V1.1 accuracy tuning empirical table.
- `planning/transcription-tuning.md` — every transcription dial (UI + hidden), current default + why, decisions log.
- `CHANGE_LOG.md` — running time-ordered narrative of what shipped and why.

Read these before making non-trivial decisions; they encode constraints that don't show up in the code (e.g. "local-first by default, cloud is opt-in", "on-device ≠ Apple-only").

## Change log maintenance (read this)

**Append an entry to `CHANGE_LOG.md` after every shippable change.** This is non-optional — the change log is how the project narrative survives across sessions. Without it, the *why* behind shipped work has to be reconstructed from `git log` (which is terse) or rediscovered (expensive).

What counts as "shippable": any commit-worthy unit of work — a feature, an architectural change, a planning pivot, a notable bug fix, a doc that future-you would want to know exists. Trivial typo fixes don't need entries.

Format:
- Add under the current date's `## YYYY-MM-DD` section. If the date has rolled over, create a new section above the previous one's bullets.
- One bullet per shippable unit. Bold lead-in summarizing what shipped, then the *why* / non-obvious context.
- Identifier-rich is good (file paths, function names, identifiers). Comma-prose is bad.
- Past tense, terse, declarative.

When to *not* write to the change log: short conversations, exploratory questions, code reading that didn't produce a change.

## Repo layout

- `Relay Notes/` — Swift source (Xcode group/target).
- `Relay Notes.xcodeproj/` — Xcode project.
- `planning/` — design docs (folder reference in Xcode, not a target member).
- `CHANGE_LOG.md` — running ship narrative at the repo root.

### Info.plist is a hand-maintained *partial* — don't delete it

`Relay Notes/Info.plist` holds only keys Xcode can't auto-generate (currently `UIBackgroundModes = [audio]`, which makes locked-screen recording work — see `CHANGE_LOG.md` 2026-06-09). The build keeps `GENERATE_INFOPLIST_FILE = YES` *and* points `INFOPLIST_FILE` at this file; Xcode merges the generated keys (usage strings, orientations, etc.) on top of it. Two gotchas: (1) `INFOPLIST_KEY_UIBackgroundModes` is a no-op — that key isn't in Xcode's generatable allowlist, hence the file. (2) The target uses a file-system-synchronized group, so the file is excluded from Copy Bundle Resources via a `PBXFileSystemSynchronizedBuildFileExceptionSet` in the pbxproj — without that exception you get "Multiple commands produce Info.plist". Add new non-generatable plist keys here, not via `INFOPLIST_KEY_*`.

## Build & validate

Use the `xcode-tools` MCP server (see global CLAUDE.md). Order of preference for verifying work:

1. `XcodeRefreshCodeIssuesInFile` — fast per-file diagnostics. Run after every edit.
2. `BuildProject` — full build. Run before claiming a multi-file change works.
3. **No test target exists yet** (per `planning/notes.md` 2026-06-08 log). When tests are added, the plan is the Swift `Testing` framework for unit tests and XCUIAutomation for UI tests.

There is no linter configured.

## Architecture spine — provider abstraction

The defining pattern: every external capability is hidden behind a protocol so the runtime provider is swappable without rebuilding. This is load-bearing — preserve it when adding features.

### Transcriber has TWO methods, both intentional

`Transcription/Transcriber.swift` defines:

```swift
protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, options: TranscriptionOptions) async throws -> String
    func makeStreamingSession(options: TranscriptionOptions) async throws -> any TranscriptionSession
}
```

- `transcribe(_:options:)` — file-based. **Currently unused by the app.** Do not delete as dead code. Reserved for future cloud STT providers (Cohere, Gemini) which work on uploaded files, and for a potential "re-transcribe this note" action.
- `makeStreamingSession(options:)` — streaming. This is what `RecorderViewModel` uses today.

Both paths share one `AppleSpeechTranscriber`. Streaming wraps `SpeechAnalyzer.start(inputSequence:)` over an `AsyncStream<AnalyzerInput>`; file-based wraps `SpeechAnalyzer.analyzeSequence(from:)`. Differences between the two paths are documented in `planning/transcription-tuning.md` ("Streaming vs file-based").

### Audio capture pipeline

`Audio/LiveAudioEngine.swift` (`@MainActor`) installs an input tap on `AVAudioEngine` and does **double duty** per buffer:
1. Writes AAC/m4a to disk via `AVAudioFile(forWriting:settings:)` for later playback.
2. Converts the PCM buffer to the analyzer's preferred format via `AVAudioConverter` and yields it to an `AsyncStream<AVAudioPCMBuffer>` consumed by the `TranscriptionSession`.

The tap block runs on the audio thread → it holds a `@unchecked Sendable` `TapState` helper (single-thread access by construction). Don't try to make `LiveAudioEngine` itself non-isolated; the setup/teardown happens on `@MainActor`.

### Runtime tuning flow

`Recording/Tunings.swift` is an `@Observable` model persisted via `UserDefaults` (`didSet` on every property writes; `init` reads back). It exposes:
- `recordingOptions: RecordingOptions` (consumed by `LiveAudioEngine.start`)
- `transcriptionOptions: TranscriptionOptions` (consumed by `Transcriber.makeStreamingSession`)

`RecorderViewModel` reads a snapshot of these *at the moment of starting a recording*, so changes mid-record don't take effect until the next session. This is intentional.

UI lives in `Views/SettingsView.swift` (mode / bitrate / preset / contextual strings). What each dial *does* and *why we chose its default* is in `planning/transcription-tuning.md`. What we've *observed empirically* lives in `planning/notes.md § V1.1 accuracy tuning`.

### Persistence

SwiftData for `Note`. Audio files live in `URL.documentsDirectory` and are referenced by **`audioFilename: String`**, not absolute URL — the container path can shift between launches. `Note.audioURL` resolves the filename against `URL.documentsDirectory` at access time. Don't store URLs directly.

`Note.deleteWithAudio(in:)` is the canonical delete — it removes both the SwiftData row and the audio file from disk. Always use it for deletion (never `modelContext.delete(note)` alone, which would orphan the audio file).

## Provider expansion (when L stages resume)

The plan in `planning/notes.md` extends the same provider pattern to `LanguageModel`:
- **MLX** is the default local engine. Apple Foundation Models are explicitly *not* the primary engine — they're an optional fourth provider. This is a deliberate stance based on capability comparison as of mid-2026.
- **Cloud is opt-in only**, never implicit. The app must remain fully functional with no network.

If you find yourself reaching for Apple Foundation Models or cloud-by-default, you're going against the design — re-read the intro callouts in `planning/notes.md`.

## Conventions specific to this codebase

- **`@MainActor @Observable`** for view-state types that hold mutable UI state. View models are constructed lazily in `ContentView.task` and injected into views.
- **Swift 6 strict concurrency** — both `AudioPlayer` and `LiveAudioEngine` are `@MainActor`; the audio-thread surfaces use explicit Sendable boundaries. Polling for playback progress uses a `Task` loop, not `Timer`, to keep concurrency clean.
- **Tap-to-record state machine** lives in `RecorderViewModel.State`: `.idle / .recording(partial:) / .finalizing / .finished / .failed`. The `partial` is updated from the streaming transcriber's `updates` stream while recording.
- **Error messages shown to users are generic and actionable** (e.g. "Couldn't start recording. Please try again."). Specific framework errors stay in logs / debugger.
