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

### Whisper assets are bundled and resources are flat at the .app root

For T1.1b, Whisper's small assets live in `Relay Notes/Relay Notes/Resources/whisper-tiny.en/` and get picked up automatically by the synchronized-group rule. The 75 MB `weights.npz` is **gitignored** and fetched via `scripts/fetch-whisper-tiny.sh` (which calls `scripts/convert-whisper-assets.py` to convert npz → safetensors, since `mlx-swift`'s `loadArrays(url:)` only reads safetensors — Python `mlx.load` handles both, the Swift binding doesn't). T1.2 will replace this bundling pattern with an in-app URLSession download into Application Support; the on-disk layout there will use real subdirectories.

**Resources are flat in the built app** — Xcode's file-system-synchronized group does not preserve the `Resources/whisper-tiny.en/` hierarchy at build time, so `Bundle.main.url(forResource:withExtension:)` lookups *omit* the `subdirectory:` argument. Fine for T1.1b (single model variant); revisit if we ever bundle multiple variants whose filenames would collide.

### MLX tests are device-only — gate with `#if !targetEnvironment(simulator)`

`mlx-swift` crashes on the iOS Simulator because the simulator's Metal GPU does not advertise the required `MTLGPUFamily`. Any test that allocates an `MLXArray` or calls an MLX op kills the test runner mid-suite and takes the rest of the tests down with it. Convention for `Relay NotesTests/Whisper*Tests.swift`:

- **Simulator-safe** tests (constants, precondition error throwing, AVFoundation-only paths) live at the top of the suite and run on every `xcodebuild test`.
- **Device-only** tests (anything touching `MLXArray`, `loadArrays`, MLX-using helpers) are gated behind `#if !targetEnvironment(simulator)`. They compile but never execute on the simulator.
- The corresponding numerical / shape validation happens via the `#if DEBUG` smoke button in the Tuning sheet (`MLXSmoke.run()` → exercises each Whisper sub-pipeline on the iPhone 15 Pro Max and prints to the Xcode console).

## Build & validate

Use the `xcode-tools` MCP server (see global CLAUDE.md). Order of preference for verifying work:

1. `XcodeRefreshCodeIssuesInFile` — fast per-file diagnostics. Run after every edit.
2. `BuildProject` — full build. Run before claiming a multi-file change works.
3. **Tests:** the `Relay NotesTests` target uses the Swift `Testing` framework (`import Testing`, `@Test`/`#expect`), hosted in the app (`@testable import Relay_Notes`). Run with: `xcodebuild test -project "Relay Notes.xcodeproj" -scheme "Relay Notes" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Coverage is currently thin (just the recorder interruption state-transition logic) — grow it as logic accrues. UI tests (XCUIAutomation) are still unplanned. The scheme `Relay Notes` is **shared** (`xcshareddata/xcschemes/`) so the test action is reproducible from the CLI.

There is no linter configured.

**Editing the `.xcodeproj` (adding targets, files, build settings):** prefer the `xcodeproj` Ruby gem over hand-editing `project.pbxproj`. The project uses Xcode 16 file-system-synchronized groups; the gem (1.27.0) round-trips them safely (it reorders sections but preserves the sync groups and the `PBXFileSystemSynchronizedBuildFileExceptionSet`). Validate any project mutation on a full-repo copy in `/tmp` (build + test there) before applying it to the real project — git is the backstop if it goes wrong.

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
- **Tap-to-record state machine** lives in `RecorderViewModel.State`: `.idle / .recording(partial:) / .paused(partial:) / .finalizing / .finished / .failed`. The `partial` is updated from the streaming transcriber's `updates` stream while recording. `.paused` is driven by `AVAudioSession` interruptions (call/alarm/Siri): `LiveAudioEngine` surfaces them as an `AsyncStream<InterruptionEvent>` (`.began`/`.resumed`/`.stopped`) on the `LiveRecording`; `.began` → paused, `.resumed` → recording, `.stopped` → auto-finalize (no manual-resume affordance by design).
- **Error messages shown to users are generic and actionable** (e.g. "Couldn't start recording. Please try again."). Specific framework errors stay in logs / debugger.
