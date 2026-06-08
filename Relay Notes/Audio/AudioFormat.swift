import AVFoundation
import Foundation

struct AudioFormat: Sendable {
    let fileExtension: String
    let formatID: AudioFormatID

    nonisolated static let m4aAAC = AudioFormat(
        fileExtension: "m4a",
        formatID: kAudioFormatMPEG4AAC
    )
}
