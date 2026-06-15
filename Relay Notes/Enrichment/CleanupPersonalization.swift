import Foundation

/// The user's personalization for transcript cleanup — domain context and the
/// names / jargon / acronyms the cleanup model should spell correctly. A plain
/// `Sendable` value that crosses the `LanguageModel.clean` boundary; the cleanup
/// analogue of `AppleSpeechOptions.contextualStrings` for transcription.
///
/// This is the *domain* representation. The *editable* representation — the raw
/// text the user types in the Tuning sheet — lives in `Tunings.cleanup`
/// (`CleanupSettings`), exactly as `AppleSpeechSettings.contextualStringsText`
/// (raw) maps to `AppleSpeechOptions.contextualStrings` (parsed). The *wording*
/// of the prompt these become is owned by `CleanupPrompt`, so the single source
/// of truth for the instruction stays in one place (no per-call drift).
struct CleanupPersonalization: Sendable, Equatable {
    /// Subject areas / domains the speaker's notes cover (free text).
    var domains: String
    /// Names, jargon, and acronyms the model should spell correctly (free text).
    var terms: String

    /// The empty personalization — cleaning with this composes exactly the base
    /// `CleanupPrompt`, i.e. behavior unchanged from before personalization.
    static let none = CleanupPersonalization(domains: "", terms: "")

    var trimmedDomains: String { domains.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTerms: String { terms.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// No usable content in either field (whitespace-only counts as empty), so the
    /// prompt should carry no personalization block at all.
    var isEmpty: Bool { trimmedDomains.isEmpty && trimmedTerms.isEmpty }
}
