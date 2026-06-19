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
    /// transcript).
    ///
    /// `personalization` carries the user's domain context (subject areas + the
    /// names/jargon/acronyms to spell correctly). It biases recognition-error
    /// fixes only — never licenses adding content. Pass `.none` for the
    /// un-personalized prompt (or use the `clean(_:)` convenience). The instruction
    /// text — including how personalization is framed — is centralized in
    /// `CleanupPrompt` (L2.1) so swapping providers never changes behavior.
    func clean(_ raw: String, personalization: CleanupPersonalization) async throws -> String

    /// Release any loaded weights / GPU buffers so the model isn't resident while
    /// idle (and isn't co-resident with another MLX engine — §3.3). A no-op for
    /// stateless providers (e.g. a future cloud model). Part of the spine so
    /// `Cleaner` can manage lifecycle through `any LanguageModel` rather than the
    /// concrete conformer — which is also what makes it injectable for tests.
    func evict() async

    // L3 will add this additively — designed in now so adding it isn't a reshape:
    //   func categorize(_ note: String, into allowed: [String]) async throws -> Categorization
    // The model picks from `allowed`; it never invents categories (notes.md).
}

extension LanguageModel {
    /// Convenience for callers with no personalization (DEBUG smoke, previews,
    /// tests). Equivalent to `clean(raw, personalization: .none)`.
    func clean(_ raw: String) async throws -> String {
        try await clean(raw, personalization: .none)
    }
}

/// Errors surfaced by a `LanguageModel`. Kept generic at the boundary; the UI maps
/// these to generic, actionable copy (Projects/CLAUDE.md), and the specific
/// underlying error stays in logs / the debugger. Failures from inside the
/// inference engine (load, decode, OOM, …) propagate verbatim rather than being
/// re-wrapped here.
enum LanguageModelError: Error {
    /// The model's weights aren't available (not downloaded, or eviction left no
    /// loaded model). The app gates cleanup on model presence, so this is mostly
    /// defensive — it maps to a generic "try again" at the UI.
    case modelUnavailable
}
