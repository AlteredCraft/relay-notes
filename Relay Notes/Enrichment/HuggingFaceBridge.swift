import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

// MARK: - Hugging Face integration bridge (hand-rolled — L2.0, plan.L2.md §3.1)
//
// `mlx-swift-lm` (MLXLLM/MLXLMCommon) deliberately externalizes HF download +
// tokenizer loading: `Downloader` and `TokenizerLoader` are protocols only. Its
// blessed `MLXHuggingFace` product supplies the concrete conformances via Swift
// *macros* — which would pull `swift-syntax` (a compiler-plugin build dependency)
// into this app. We instead **vendor** the conformances here, transcribed verbatim
// from mlx-swift-lm's own macro expansions (`MLXHuggingFaceMacros`:
// `DownloaderMacro` / `TokenizerAdaptorMacro` / `TokenizerLoaderMacro`) and matched
// to the APIs we actually depend on (swift-huggingface 0.9.0, swift-transformers
// 1.3.3).
//
// Precise benefit: `MLXHuggingFace` is the *only* target in the whole resolved graph
// that depends on the macro plugin (`MLXHuggingFaceMacros` → swift-syntax). By not
// linking it, that plugin is never **compiled** for our build — a clean-build / CI
// time saving. swift-syntax itself stays *resolved* (Package.resolved still pins
// 600.0.1) and checked out; we only avoid compiling it as a macro plugin. (There's
// no app-size or runtime cost either way — macros are compile-time; swift-syntax
// never ships in the binary.) Plus: no macro indirection, fully auditable.
//
// If you bump swift-huggingface / swift-transformers and this stops compiling,
// re-diff against those macros — they are the upstream source of truth.
//
// Naming: `MLXLMCommon.Tokenizer` (the target protocol) and `Tokenizers.Tokenizer`
// (the swift-transformers protocol) collide, as do their `TokenizerError`s — every
// reference here is module-qualified for that reason.

enum HuggingFaceBridgeError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository id: \(id)"
        }
    }
}

/// Adapts `HuggingFace.HubClient` to `MLXLMCommon.Downloader`. Defaults to the
/// shared anonymous client (`HubClient.default`) — fine for public `mlx-community`
/// repos; swap in a token-bearing client here if we ever need gated models.
struct HubDownloaderBridge: MLXLMCommon.Downloader {
    private let upstream: HuggingFace.HubClient

    init(_ upstream: HuggingFace.HubClient = .default) {
        self.upstream = upstream
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Foundation.Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw HuggingFaceBridgeError.invalidRepositoryID(id)
        }
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

/// Adapts a `Tokenizers.Tokenizer` (swift-transformers) to `MLXLMCommon.Tokenizer`.
/// `Message` / `ToolSpec` in swift-transformers are `typealias`es for
/// `[String: any Sendable]`, so the `applyChatTemplate` dictionaries pass straight
/// through (verified against 1.3.3).
struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names the parameter `tokens:`, not `tokenIds:`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// `MLXLMCommon.TokenizerLoader` backed by `Tokenizers.AutoTokenizer`, loading from
/// the snapshot directory the downloader resolved.
struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
    init() {}

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return HuggingFaceTokenizerBridge(upstream)
    }
}
