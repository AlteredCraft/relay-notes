# Relay Notes

Personal iOS voice-notes app. Tap → speak → an on-device transcript is saved. No account, no server, works offline.

Transcription runs **on-device** two ways, swappable in Settings:
- **Apple Speech** (`SpeechAnalyzer`) — ships with iOS, streams a live transcript while you talk. Default.
- **On-device Whisper** (`whisper-small.en` via [MLX](https://github.com/ml-explore/mlx-swift)) — downloaded on first use, decodes when you stop recording.

Cloud transcription and any LLM cleanup are deliberately out of scope for v1. The guiding stance is *local-first by default; cloud is opt-in only*.

> This is a private repo and these notes are for me. They assume I'm coming back to this after a gap and may have forgotten the iOS-specific moving parts.

**Where the real docs live:**
- [`CLAUDE.md`](./CLAUDE.md) — the deep architecture + conventions doc (also what Claude Code reads). Read this before non-trivial changes.
- [`planning/notes.md`](./planning/notes.md) — the build roadmap and scope decisions. The current milestone lives here.
- [`CHANGE_LOG.md`](./CHANGE_LOG.md) — running narrative of what shipped and why.
- [`planning/transcription-tuning.md`](./planning/transcription-tuning.md) — every transcription dial and why its default is what it is.

**Status:** v1 (voice-to-text). Whisper is fully wired into the recorder (T1.2 done, 2026-06-12). Next up is T1.3 (on-device performance measurements). See `planning/notes.md` for the roadmap.

---

## The daily loop (TL;DR)

Keep Xcode **open in the background** (signing, previews, and Instruments still live there); do everything else from the terminal.

```sh
# Run tests (simulator) — the command you'll use most
xcodebuild test -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | xcbeautify

# Build only (faster sanity check)
xcodebuild build -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | xcbeautify

# Run the app in the simulator: easiest from Xcode — press Cmd-R.
```

The quotes matter — both the project filename and the scheme name contain a space.

---

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| **Xcode 26.5** | Builds the app; targets iOS 26.5. | Mac App Store / developer.apple.com |
| **Command Line Tools** | `xcodebuild`, `xcrun`, `simctl`, `devicectl`. | `xcode-select --install` (or bundled with Xcode) |
| **xcbeautify** | Makes raw `xcodebuild` output readable (it buries errors otherwise). | `brew install xcbeautify` |
| **`xcodeproj` Ruby gem** | Safely edits the `.xcodeproj` (adding files/targets) without hand-editing the project file. | `gem install xcodeproj` (have 1.27.0) |
| **uv** | *Only* for the optional model-prefetch script. Not needed for normal build/run. | [docs.astral.sh/uv](https://docs.astral.sh/uv/) |

There is **no linter** configured. Swift dependencies (`mlx-swift`, `swift-numerics`) are managed by Swift Package Manager and resolve automatically on first build — nothing to install by hand.

**Target hardware:** the personal device is an **iPhone 15 Pro Max**. The Whisper path is validated there; the iOS Simulator can't run it (see the caveat below).

---

## First-time setup

1. **Clone**, then open the project:
   ```sh
   open "Relay Notes.xcodeproj"
   ```
   Xcode resolves the Swift packages on first open/build (watch the progress bar — first resolve pulls `mlx-swift` and can take a minute).

2. **Build + run in the simulator** to confirm the toolchain is healthy: pick the **Relay Notes** scheme and an **iPhone 17 Pro** simulator in the toolbar, then press **Cmd-R**. The app launches with an empty notes list and a record button.

3. **Run the tests** (below) to confirm the test target builds and the suite is green.

That's enough to develop the app and its logic. Putting it on a physical phone (and using real Whisper) is a separate step — see *Running on your iPhone*.

---

## Running tests

The suite uses Swift's **Testing** framework (`import Testing`, `@Test`/`#expect`), hosted in the app target. As of 2026-06-12 it's **78 tests across 13 suites**, ~12 s warm.

```sh
xcodebuild test -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | xcbeautify
```

From Xcode, the equivalent is **Cmd-U** (or click the diamond next to a test/suite to run just that one).

**Run a single suite or test from the CLI** with `-only-testing` (faster iteration):

```sh
xcodebuild test -project "Relay Notes.xcodeproj" -scheme "Relay Notes" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:"Relay NotesTests/RecorderPlaceholderTests" 2>&1 | xcbeautify
```

Things worth knowing as a newcomer:
- **Any iPhone 17 Pro simulator works** — swap the `name=` for whatever `xcrun simctl list devices available` shows. You don't need a booted simulator first; `xcodebuild test` boots one.
- **MLX (Whisper math) tests are device-only.** MLX crashes the simulator's GPU, so tests that touch it are compiled but skipped on the simulator (guarded by `#if !targetEnvironment(simulator)`). The simulator run still exercises all the non-MLX logic. On-device numerical validation happens via a debug button instead (below).
- **The scheme is shared** (checked into `xcshareddata/`) — that's what makes the CLI command reproducible. Leave it shared.
- **New test files must be registered** in the project before they'll run:
  ```sh
  ruby scripts/add_test_file.rb MyNewTests.swift
  ```
  (The test target is a plain group, not an auto-syncing one, so a new file is invisible until this wires it in.)

---

## Running on your iPhone (sideload)

This is the part that's iOS-specific and easy to forget. It uses the **free Apple ID tier** — no paid Developer Program ($99/yr) yet.

**One-time:**
1. On the phone: **Settings → Privacy & Security → Developer Mode → on**, then restart.
2. Plug the phone in. In Xcode: **Signing & Capabilities** → set your personal team. Select the phone as the run destination and press **Cmd-R** to build, sign, and install.

**The 7-day catch:** free-tier signing **expires every 7 days**. When the app refuses to launch, re-build to the phone from Xcode to re-sign — your data survives (SwiftData rows + audio files persist across re-signs because the bundle ID is stable).

**After signing is valid, CLI installs work** (handy for installing a fresh build without clicking around Xcode):
```sh
xcrun devicectl list devices                       # find the phone's identifier
xcrun devicectl device install app --device <id> <path-to .app>
```
The built `.app` lands under `~/Library/Developer/Xcode/DerivedData/Relay_Notes-*/Build/Products/Debug-iphoneos/Relay Notes.app`.

**Getting the Whisper model onto the phone:** the app ships without the 481 MB weights (keeps the build ~74 MB). To use the Whisper engine, open **Settings (the slider icon) → download the model**. It downloads once from Hugging Face into the app's Application Support and is then available offline. Apple Speech needs no download.

---

## Whisper on-device: the smoke button

Because the simulator can't run MLX, on-device Whisper is validated by hand:

- The **Settings sheet** (slider icon, top-right) is also where engine selection, model download, and the tuning dials live. In a **DEBUG** build, its debug section (at the bottom) has a **"Run MLX smoke (console)"** button. Tapping it on the phone exercises each Whisper sub-pipeline and prints timings/results to the **Xcode console** (View → Debug Area, with the phone running from Xcode).
- This is the on-device counterpart to the unit tests — it's how shape/numerical correctness and timing get confirmed on real hardware.

The optional prefetch script (`scripts/fetch-whisper-model.sh [tiny.en|small.en]`, needs `uv`) downloads + converts weights into the repo for local tinkering. You **don't** need it for the normal flow — the app downloads its own model at runtime.

---

## Repo layout

```
Relay Notes/            Swift source (the Xcode app target)
  Audio/                AVAudioEngine capture, playback
  Transcription/        Transcriber protocol + Apple & Whisper/MLX providers
  Recording/            RecorderViewModel state machine, Tunings
  Views/                SwiftUI views
  Models/               SwiftData Note
Relay NotesTests/       Swift Testing suite
Relay Notes.xcodeproj/  Xcode project
planning/               Design docs (roadmap, tuning rationale) — folder reference, not a build target
scripts/                Project-maintenance helpers (add_test_file.rb, fetch-whisper-model.sh, ...)
CLAUDE.md               Architecture + conventions (start here for changes)
CHANGE_LOG.md           What shipped, in order, and why
README.md               This file
```

The app is built around a **provider abstraction**: every external capability (transcription today, LLM cleanup later) sits behind a protocol so the runtime engine is swappable. Preserve that pattern when adding features — `CLAUDE.md` explains it in depth.

---

## Common gotchas

- **Edit the project via the gem, not by hand.** Adding files/targets/build-settings to `Relay Notes.xcodeproj` is done with the `xcodeproj` Ruby gem (the project uses Xcode's file-system-synchronized groups, which the gem round-trips safely). Validate any project mutation on a `/tmp` copy first — git is the backstop.
- **`Info.plist` is a hand-maintained partial — don't delete it.** It holds only keys Xcode can't auto-generate (currently the background-audio mode for locked-screen recording). Details in `CLAUDE.md`.
- **Concurrency is strict.** The project defaults actor isolation to `MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so isolation-neutral protocols need an explicit `nonisolated`. If a build error mentions unexpected `@MainActor` inference, that's the cause — see the `Transcriber` notes in `CLAUDE.md`.
- **When the MCP/Xcode tooling is flaky,** plain `xcodebuild` (piped through `xcbeautify`) covers the whole edit → build → test loop. That's the fallback the daily-loop commands above use.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodebuild` output is an unreadable wall of text | Pipe it: `... 2>&1 \| xcbeautify`. If `xcbeautify` isn't found: `brew install xcbeautify`. |
| App won't launch on the phone after a few days | Free-tier signing expired — re-build to the device from Xcode to re-sign. |
| A new test file's tests never run | Register it: `ruby scripts/add_test_file.rb <File>.swift`. |
| Whisper engine missing / unselectable in Settings | The model isn't downloaded — open Settings and download it (Whisper is gated on a present model by design). |
| Tests crash mid-suite mentioning Metal/GPU | An MLX test ran on the simulator — it should be `#if !targetEnvironment(simulator)`-gated. Validate that path on the phone via the smoke button instead. |
| Simulator name not found | `xcrun simctl list devices available` and use a name from the list. |
