import Foundation

enum TranscriptionEngine: String, Sendable, CaseIterable {
    case apple
    case whisperMLX
    case parakeetMLX

    var displayName: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisperMLX: return "On-device (Whisper)"
        case .parakeetMLX: return "On-device (Parakeet)"
        }
    }
}
