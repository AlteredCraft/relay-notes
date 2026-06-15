import Testing
@testable import Relay_Notes

/// Sim-safe coverage for `CleanupTokenBudget` — the per-call `maxTokens` cap that
/// bounds a cleanup decode so a runaway repetition loop self-terminates (GH #12).
/// Pure integer math; no MLX.
struct CleanupTokenBudgetTests {

    /// Inputs whose token estimate is small enough that the floor wins. With the
    /// current constants the floor holds up to ~`minimumTokens / outputMultiplier`
    /// input tokens; all of these sit comfortably under that (and the negative case
    /// pins the defensive `max(0, …)` clamp).
    @Test(arguments: [-100, 0, 1, 4, 100, 500])
    func shortInputGetsTheFloor(characters: Int) {
        #expect(
            CleanupTokenBudget.maxTokens(forRawCharacterCount: characters)
                == CleanupTokenBudget.minimumTokens)
    }

    /// Above the floor's break-even the cap tracks input length: 8000 chars ≈ 2000
    /// input tokens × 4 = 8000, well above the floor.
    @Test func longInputScalesAboveTheFloor() {
        let cap = CleanupTokenBudget.maxTokens(forRawCharacterCount: 8_000)
        #expect(cap == 8_000)
        #expect(cap > CleanupTokenBudget.minimumTokens)
    }

    /// The cap never decreases as the input grows — a longer transcript may need a
    /// larger budget, never a smaller one.
    @Test func capIsMonotonicNonDecreasingInInput() {
        let lengths = [0, 100, 1_000, 5_000, 20_000, 100_000]
        let caps = lengths.map { CleanupTokenBudget.maxTokens(forRawCharacterCount: $0) }
        #expect(caps == caps.sorted())
    }

    /// Every input — including pathological ones — yields a finite, positive cap at
    /// or above the floor. The whole point is that the decode is *always* bounded.
    @Test(arguments: [Int.min, -1, 0, 1, 50_000, Int.max])
    func everyInputIsBoundedAtOrAboveTheFloor(characters: Int) {
        #expect(
            CleanupTokenBudget.maxTokens(forRawCharacterCount: characters)
                >= CleanupTokenBudget.minimumTokens)
    }
}
