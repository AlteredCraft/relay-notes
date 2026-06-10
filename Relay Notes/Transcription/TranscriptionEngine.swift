import Foundation

enum TranscriptionEngine: String, Sendable, CaseIterable {
    case apple
    case whisperMLX

    var displayName: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisperMLX: return "On-device (Whisper)"
        }
    }
}

enum WhisperModelVariant: String, Sendable, CaseIterable {
    case smallEN = "small.en"
    case tinyEN = "tiny.en"

    var displayName: String {
        switch self {
        case .smallEN: return "Small (English)"
        case .tinyEN: return "Tiny (English)"
        }
    }

    var huggingFaceRepoID: String {
        switch self {
        case .smallEN: return "mlx-community/whisper-small.en-mlx"
        case .tinyEN: return "mlx-community/whisper-tiny.en-mlx"
        }
    }

    var approxDownloadMB: Int {
        switch self {
        case .smallEN: return 250
        case .tinyEN: return 75
        }
    }
}
