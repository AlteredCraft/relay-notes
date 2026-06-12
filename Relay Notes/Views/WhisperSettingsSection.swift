import SwiftUI

/// Engine-specific Settings group for **on-device Whisper**. Shown when
/// `engine == .whisperMLX` (Approach C). v1 Whisper has no adjustable decode
/// dials, so this is an explanatory placeholder — it tells the user the empty
/// state is intentional (rather than "did the settings disappear?") and marks
/// where future Whisper dials (bound to `tunings.whisper`) will land. Model
/// download/delete lives in the always-shown `WhisperModelSection`, not here,
/// so it stays reachable while Apple is selected.
struct WhisperSettingsSection: View {
    var body: some View {
        Section {
            Text("On-device Whisper transcribes with fixed settings in v1 — there's nothing to tune here. Manage its model under \u{201C}On-device model\u{201D} above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Recognition")
        }
    }
}
