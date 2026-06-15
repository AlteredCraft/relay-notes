import Foundation
import Testing
@testable import Relay_Notes

/// Sim-safe, offline coverage for `HubDownloaderBridge` — the HF download adapter
/// (GH #13). The only branch reachable without a network or MLX is the repo-id
/// validation: `HuggingFace.Repo.ID(rawValue:)` returns nil for a string that
/// doesn't split into exactly two `/`-separated parts, and the bridge converts that
/// into `HuggingFaceBridgeError.invalidRepositoryID` *before* touching the upstream
/// client. The download itself stays device/network-only.
struct HuggingFaceBridgeTests {

    /// A `Progress` sink that fails the test if it ever fires — proves we threw
    /// before any download work began.
    private func failingProgress(_: Progress) {
        Issue.record("progressHandler must not be called for an invalid repo id")
    }

    /// Repo ids with no namespace/name split (no `/`, or empty) are rejected up
    /// front, before any network call.
    @Test(arguments: ["no-slash", "", "   "])
    func malformedRepoIDThrowsInvalidRepositoryID(id: String) async {
        let bridge = HubDownloaderBridge()
        await #expect(throws: HuggingFaceBridgeError.self) {
            _ = try await bridge.download(
                id: id,
                revision: nil,
                matching: [],
                useLatest: false,
                progressHandler: failingProgress)
        }
    }

    /// The thrown error carries the offending id (for logs) — pin the specific case,
    /// not just the error type.
    @Test func errorCarriesTheOffendingID() async {
        let bridge = HubDownloaderBridge()
        do {
            _ = try await bridge.download(
                id: "missing-namespace",
                revision: nil,
                matching: [],
                useLatest: false,
                progressHandler: failingProgress)
            Issue.record("expected download to throw for an invalid repo id")
        } catch let HuggingFaceBridgeError.invalidRepositoryID(reported) {
            #expect(reported == "missing-namespace")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
