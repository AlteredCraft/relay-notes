import Foundation

/// The one source of truth for the cleanup instruction (plan.L2.md §3.5/§5.3).
/// Centralized so swapping `LanguageModel` providers never changes behavior and
/// there's no per-call prompt drift.
///
/// Structured for chat models: `system(personalization:)` is the directive, and
/// the **raw transcript is sent as the user turn** (see `MLXLanguageModel.clean`).
/// The model's chat template is applied by the tokenizer — we never hand-bake it
/// (templates differ per family; that's the §10 "prompt tuning" caveat — hold the
/// directive fixed across the L2.3 head-to-head, tune only after a winner is chosen).
///
/// **Personalization** (the user's domains + terms, from `Tunings.cleanup`) rides
/// in as an optional background block. It's framed as recognition/spelling help
/// only — never license to add content — and inserted *between* the rules and the
/// closing output rule so "output only the cleaned transcript" always lands last.
enum CleanupPrompt {
    /// The fixed cleanup directive — everything except the closing output rule,
    /// which is appended last so personalization can never displace it.
    private static let directive = """
        You are a transcript cleanup assistant. The text the user sends is a raw \
        speech-to-text transcript of a spoken voice note. It may contain filler \
        words, false starts, run-on sentences, missing punctuation, and recognition \
        errors where a word was misheard.

        Clean it up:
        - Remove fillers and false starts (um, uh, "like", repeated words, self-corrections).
        - Add punctuation, capitalization, and paragraph breaks.
        - Fix obvious misrecognitions ONLY when the intended word is clear from context.
        - Preserve the speaker's meaning, wording, and all information. \
        Do NOT summarize, shorten, add facts, or change the substance.
        - If a word is garbled and you can't infer it, leave it or mark it [unclear].
        """

    /// Always the final line of the system prompt (strongest recency).
    private static let outputRule = "Output only the cleaned transcript, nothing else."

    /// The cleanup system prompt, optionally personalized. With `.none` (the
    /// default) this is the fixed directive — byte-for-byte the pre-personalization
    /// prompt. With domains/terms set, a clearly-delimited background block is
    /// inserted; the output rule still lands last.
    static func system(personalization: CleanupPersonalization = .none) -> String {
        var parts = [directive]
        if let block = personalizationBlock(personalization) {
            parts.append(block)
        }
        parts.append(outputRule)
        return parts.joined(separator: "\n\n")
    }

    /// The wording of the personalization block — owned here so `CleanupPrompt`
    /// stays the single source of truth for the instruction text. `nil` when the
    /// user supplied nothing usable. The framing is deliberately defensive: the
    /// model may use this to *spell* and *disambiguate*, never to inject content
    /// (the cardinal sin — an LLM "improving" a note with invented detail).
    private static func personalizationBlock(_ p: CleanupPersonalization) -> String? {
        guard !p.isEmpty else { return nil }
        var lines = [
            "Background about this speaker, to help you recognize and correctly spell domain-specific words. Use it ONLY for spelling and disambiguation — do NOT add any of it to the transcript or change the speaker's meaning."
        ]
        if !p.trimmedDomains.isEmpty {
            lines.append("- Subject areas / domains: \(p.trimmedDomains)")
        }
        if !p.trimmedTerms.isEmpty {
            lines.append("- Names, jargon, and acronyms (spell exactly as written here when you hear them): \(p.trimmedTerms)")
        }
        return lines.joined(separator: "\n")
    }
}
