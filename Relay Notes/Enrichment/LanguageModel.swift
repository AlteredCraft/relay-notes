import Foundation

/// The cleanup-model spine — the LLM-enrichment analogue of `Transcriber`. The
/// runtime provider (on-device MLX today; cloud opt-in later) sits behind this
/// protocol so it's swappable without a rebuild, exactly as transcription sits
/// behind `Transcriber` (see `planning/notes.md` "The spine" and
/// `planning/plan.L2.md` §3.5/§5.1). Adding a provider = a new conformer + a
/// factory arm, never a special-case.
///
/// `nonisolated` for the same reason `Transcriber` / `TranscriptionSession` are:
/// the protocol is isolation-neutral and each conformer picks its own isolation
/// (the MLX conformer is an `actor`). Under the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated protocol is
/// implicitly `@MainActor` and conformance inference leaks that onto conformers —
/// the trap documented in CLAUDE.md / CHANGE_LOG 2026-06-11. Protocols are *not*
/// on SE-0466's exemption list.
///
/// **Naming note:** `MLXLMCommon` (a product of the `mlx-swift-lm` dependency)
/// also exports a public `LanguageModel` — *its* core on-device-model protocol.
/// The two don't clash here (this file imports nothing from that package). The
/// collision is handled in `MLXLanguageModel.swift`, the one place that imports
/// both, by qualifying this protocol as `Relay_Notes.LanguageModel`.
nonisolated protocol LanguageModel: Sendable {
    /// Clean a raw speech-to-text transcript: remove fillers / false starts, fix
    /// run-ons and punctuation, add light structure — **preserving the speaker's
    /// meaning and all content.** No summarizing, no invented facts (the cardinal
    /// sin: an LLM "improving" a note by inventing detail is worse than a raw
    /// transcript). The instruction text is centralized in `CleanupPrompt` (L2.1)
    /// so swapping providers never changes behavior.
    func clean(_ raw: String) async throws -> String

    // L3 will add this additively — designed in now so adding it isn't a reshape:
    //   func categorize(_ note: String, into allowed: [String]) async throws -> Categorization
    // The model picks from `allowed`; it never invents categories (notes.md).
}

/// Errors surfaced by a `LanguageModel`. Kept generic at the boundary; the UI maps
/// these to generic, actionable copy (Projects/CLAUDE.md), and the specific
/// underlying error stays in logs / the debugger.
enum LanguageModelError: Error {
    /// The model's weights aren't available (not downloaded, or eviction left no
    /// loaded model). The app gates cleanup on model presence, so this is mostly
    /// defensive — it maps to a generic "try again" at the UI.
    case modelUnavailable
    /// Generation failed inside the inference engine (load, decode, OOM, …).
    case generationFailed(any Error)
}
