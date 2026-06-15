import Testing
@testable import Relay_Notes

/// Pure-string coverage for `CleanupPrompt.system(personalization:)` — the prompt
/// composition that cleanup personalization rides on. Sim-safe (no MLX); the
/// actual generation is device-only (validated via `LLMCleanupSmoke` / dogfooding).
struct CleanupPromptTests {

    private let outputRule = "Output only the cleaned transcript, nothing else."

    @Test func emptyPersonalizationOmitsBackgroundBlock() {
        let prompt = CleanupPrompt.system(personalization: .none)
        #expect(!prompt.contains("Background about this speaker"))
        #expect(prompt.contains("You are a transcript cleanup assistant"))
    }

    /// GH #13: pin the cardinal-sin guard — the whole feature rests on the model
    /// never summarizing or inventing. Must survive in *every* prompt variant,
    /// personalized or not (personalization must not be able to dilute it).
    @Test func everyPromptKeepsTheNoInventGuard() {
        let variants = [
            CleanupPrompt.system(personalization: .none),
            CleanupPrompt.system(personalization: CleanupPersonalization(domains: "ML", terms: "MLX"))
        ]
        for prompt in variants {
            #expect(!prompt.isEmpty)
            #expect(prompt.contains("Do NOT summarize, shorten, add facts, or change the substance."))
        }
    }

    @Test func defaultArgumentIsNone() {
        #expect(CleanupPrompt.system() == CleanupPrompt.system(personalization: .none))
    }

    @Test func outputRuleAlwaysLandsLast() {
        #expect(CleanupPrompt.system(personalization: .none).hasSuffix(outputRule))
        let personalized = CleanupPrompt.system(
            personalization: CleanupPersonalization(domains: "iOS dev", terms: "MLX, Parakeet"))
        #expect(personalized.hasSuffix(outputRule))
    }

    @Test func domainsOnlyAppearWithoutTermsLine() {
        let prompt = CleanupPrompt.system(
            personalization: CleanupPersonalization(domains: "on-device ML", terms: ""))
        #expect(prompt.contains("Background about this speaker"))
        #expect(prompt.contains("Subject areas / domains: on-device ML"))
        #expect(!prompt.contains("Names, jargon, and acronyms"))
    }

    @Test func termsOnlyAppearWithoutDomainsLine() {
        let prompt = CleanupPrompt.system(
            personalization: CleanupPersonalization(domains: "", terms: "MLX, Parakeet"))
        #expect(prompt.contains("Names, jargon, and acronyms"))
        #expect(prompt.contains("MLX, Parakeet"))
        #expect(!prompt.contains("Subject areas / domains"))
    }

    @Test func bothFieldsAppearWhenSet() {
        let prompt = CleanupPrompt.system(
            personalization: CleanupPersonalization(domains: "iOS development", terms: "SwiftData"))
        #expect(prompt.contains("Subject areas / domains: iOS development"))
        #expect(prompt.contains("SwiftData"))
    }

    // MARK: - CleanupPersonalization

    @Test func whitespaceOnlyIsTreatedAsEmpty() {
        let p = CleanupPersonalization(domains: "   \n", terms: "\t")
        #expect(p.isEmpty)
        // Whitespace-only ⇒ no background block ⇒ identical to the bare prompt.
        #expect(CleanupPrompt.system(personalization: p) == CleanupPrompt.system())
    }

    @Test func anyContentMakesItNonEmpty() {
        #expect(!CleanupPersonalization(domains: "x", terms: "").isEmpty)
        #expect(!CleanupPersonalization(domains: "", terms: "y").isEmpty)
        #expect(CleanupPersonalization.none.isEmpty)
    }

    @Test func fieldsAreTrimmedIntoThePrompt() {
        // Surrounding whitespace is stripped at the prompt edge (raw text persists).
        let prompt = CleanupPrompt.system(
            personalization: CleanupPersonalization(domains: "  ML  ", terms: "  MLX  "))
        #expect(prompt.contains("Subject areas / domains: ML\n"))
        #expect(prompt.contains("when you hear them): MLX"))
    }
}
