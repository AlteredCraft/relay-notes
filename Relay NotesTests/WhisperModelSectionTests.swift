import Foundation
import Testing
@testable import Relay_Notes

/// Covers the one piece of `WhisperModelSection` worth unit-testing: the
/// `FailureReason` → user-facing copy mapping. The view itself is SwiftUI
/// (XCUI territory, still unplanned), but the copy must stay **generic and
/// actionable** and must never leak the internal detail the `FailureReason`
/// carries for logs (HTTP status codes, missing asset names). These tests pin
/// that contract.
struct WhisperModelSectionTests {

    private let allReasons: [WhisperModelStore.FailureReason] = [
        .network,
        .server(statusCode: 503),
        .integrityCheckFailed,
        .diskWriteFailed,
        .bundledAssetMissing("config.json"),
        .cancelled,
    ]

    @Test func everyReasonHasNonEmptyCopy() {
        for reason in allReasons {
            let message = WhisperModelSection.failureMessage(for: reason)
            #expect(!message.isEmpty)
        }
    }

    @Test func serverReasonHidesStatusCode() {
        let message = WhisperModelSection.failureMessage(for: .server(statusCode: 503))
        #expect(!message.contains("503"))
    }

    @Test func bundledAssetReasonHidesAssetName() {
        let message = WhisperModelSection.failureMessage(for: .bundledAssetMissing("config.json"))
        #expect(!message.contains("config"))
        #expect(!message.contains(".json"))
    }

    /// Actionable copy points the user at something they can do. Cancellation is
    /// the one benign case — it's a state report, not an error to act on.
    @Test func nonCancelReasonsAreActionable() {
        for reason in allReasons where reason != .cancelled {
            let message = WhisperModelSection.failureMessage(for: reason).lowercased()
            #expect(
                message.contains("try again")
                    || message.contains("later")
                    || message.contains("space")
                    || message.contains("connection")
            )
        }
    }
}
