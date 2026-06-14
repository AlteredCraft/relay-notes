import SwiftUI

/// Engine-specific Settings group for **on-device Parakeet**. Shown when
/// `engine == .parakeetMLX` (Approach C). v1 Parakeet has no adjustable decode
/// dials, so this is an explanatory placeholder — it tells the user the empty
/// state is intentional (rather than "did the settings disappear?") and marks
/// where future Parakeet dials (bound to `tunings.parakeet`) will land. Model
/// download/delete lives in the always-shown `ParakeetModelSection`, not here, so
/// it stays reachable while another engine is selected. Mirrors
/// `WhisperSettingsSection`.
struct ParakeetSettingsSection: View {
    var body: some View {
        Section {
            Text("On-device Parakeet transcribes with fixed settings in v1 — there's nothing to tune here. Manage its model under \u{201C}On-device model (Parakeet)\u{201D} above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Recognition")
        }
    }
}
