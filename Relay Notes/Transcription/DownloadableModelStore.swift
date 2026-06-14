import CryptoKit
import Foundation
import Observation

/// Declarative manifest for a downloadable on-device model bundle. One spec per
/// model variant; the generic `DownloadableModelStore` is driven entirely by it,
/// so adding a model is a data change, not a new store type (T2.2).
///
/// A bundle is some **remote files** (fetched over the network, each integrity-
/// checked by SHA-256 + byte size) plus some **bundled files** (small assets
/// copied from `Bundle.main` at download time — Whisper's config/tokenizer/mels;
/// Parakeet has none, its config is a remote file). All live flat in
/// `Application Support/<subdirectory…>/`.
nonisolated struct ModelDownloadSpec: Sendable {

    /// A network-fetched file, pinned to an immutable URL + content hash.
    struct RemoteFile: Sendable {
        /// Pin to a **commit SHA** path (`/resolve/<sha>/…`), never `/main/`, so
        /// the bytes at this URL can't change underneath the hash.
        let url: URL
        /// SHA-256 of the file content (the Git-LFS `oid` from HF's tree API for
        /// LFS files; computed from the pinned bytes for small non-LFS files).
        let sha256: String
        /// Exact byte count — lets us fail fast before hashing a truncated file.
        let size: Int64
        /// Filename to install as under the model directory (Whisper renames
        /// `model.safetensors` → `weights.safetensors`; Parakeet keeps names).
        let destFilename: String
    }

    /// A small asset staged from `Bundle.main` into the model directory.
    struct BundledFile: Sendable {
        let name: String
        let ext: String
        var filename: String { "\(name).\(ext)" }
    }

    /// Path components under Application Support, e.g. `["whisper", "small.en"]`.
    let subdirectory: [String]
    /// Network files; **the model is "ready" when all of these are present.**
    let remoteFiles: [RemoteFile]
    /// Bundle-staged files (may be empty).
    let bundledFiles: [BundledFile]
    /// Approximate total download size in MB, for Settings copy.
    let downloadSizeMB: Int
}

// MARK: - Pinned specs

extension ModelDownloadSpec {

    /// `mlx-community/whisper-small.en-fp16` — 481 MB FP16 weights downloaded;
    /// config/tokenizer/mel-filters staged from the bundle (small, version-locked
    /// with the Swift port). Pinned to commit `f8ff44ec…`.
    static let whisperSmallEn = ModelDownloadSpec(
        subdirectory: ["whisper", "small.en"],
        remoteFiles: [
            RemoteFile(
                url: URL(string:
                    "https://huggingface.co/mlx-community/whisper-small.en-fp16/resolve/"
                    + "f8ff44ec66c4b1748fb2e3eb13b3b521a0bdfea8/model.safetensors")!,
                sha256: "36375db96d2900eceb62ed9fe43dec23854266adc6d7ad827f661b81fb0893b4",
                size: 481_213_970,
                destFilename: "weights.safetensors"),
        ],
        bundledFiles: [
            BundledFile(name: "config", ext: "json"),
            BundledFile(name: "gpt2", ext: "tiktoken"),
            BundledFile(name: "mel_filters", ext: "safetensors"),
        ],
        downloadSizeMB: 480)

    /// `mlx-community/parakeet-tdt-0.6b-v2` — both the 2.47 GB F32 weights **and**
    /// `config.json` are downloaded (nothing bundled; the config carries the 1024-
    /// entry vocabulary the decoder needs, too big to bundle by hand). Pinned to
    /// commit `b8e276dc…`. SHA-256s: weights = the Git-LFS oid; config = computed
    /// from the pinned bytes (it's a plain, non-LFS file). Size 2 471 559 904 B
    /// matches the device's on-disk 2357 MB.
    static let parakeetTDT06bV2 = ModelDownloadSpec(
        subdirectory: ["parakeet", "tdt-0.6b-v2"],
        remoteFiles: [
            RemoteFile(
                url: URL(string:
                    "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/"
                    + "b8e276dc1b4645dc90ddb6d7b22fa82e9773f685/model.safetensors")!,
                sha256: "b958c37a6baa6874a279108755c8f2818e27bf647d72d54800a234a421341dfe",
                size: 2_471_559_904,
                destFilename: "model.safetensors"),
            RemoteFile(
                url: URL(string:
                    "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/"
                    + "b8e276dc1b4645dc90ddb6d7b22fa82e9773f685/config.json")!,
                sha256: "9bd323e60afe2615c983a5d9fc3a2c0470df2a03edf90c0f861bd59509d07264",
                size: 36_176,
                destFilename: "config.json"),
        ],
        bundledFiles: [],
        downloadSizeMB: 2357)
}

// MARK: - Store

/// Owns the on-disk presence of a model bundle and the URLSession download that
/// brings it in, driven by a `ModelDownloadSpec`. Generalized from the original
/// Whisper-only store (T2.2): a `WhisperModelStore` / `ParakeetModelStore` is just
/// this class bound to its spec.
///
/// **Why download (not bundle) the big weights:** they're hundreds of MB to GBs,
/// redownloadable, and excluded from iCloud backup per Apple's review guidelines.
/// **Why pin URLs to a commit SHA + verify SHA-256:** the file content is then
/// immutable and a corrupt/truncated download is refused before it can load as
/// garbage.
///
/// Not `final` so the per-model subclasses can add a no-arg `init()` bound to
/// their spec; they add no stored properties, so observation is unaffected.
@MainActor
@Observable
class DownloadableModelStore {

    enum Status: Equatable {
        case missing
        case downloading(progress: Double)
        case ready
        case failed(reason: FailureReason)
    }

    /// Granular failure cases — surfaced to the user as a generic "please try
    /// again" message at the UI layer; the specific reason is for logs and the
    /// retry UX (e.g. an integrity failure cleans the partial file before retry).
    enum FailureReason: Equatable {
        case network
        case server(statusCode: Int)
        case integrityCheckFailed
        case diskWriteFailed
        case bundledAssetMissing(String)
        case cancelled
    }

    enum StoreError: Error {
        case bundledAssetMissing(String)
        case unexpectedHTTPStatus(Int)
        case integrityCheckFailed(expected: String, got: String)
        case alreadyDownloading
    }

    let spec: ModelDownloadSpec

    private(set) var status: Status = .missing

    /// The on-disk directory holding the model bundle. Stable for the process.
    let modelDirectory: URL

    /// Once `status == .ready`, the location consumers load from. (Reuses the
    /// Whisper-named `WhisperModelLocation` — it's really just a `.directory(URL)`
    /// wrapper; a rename to a model-neutral name can come with T2.5.)
    var location: WhisperModelLocation { .directory(modelDirectory) }

    /// The location to load from right now, or `nil` when the bundle isn't usable
    /// (missing / mid-download / failed). Kept here (not on the consumer) so the
    /// `status == .ready` read stays on the main actor.
    var activeLocation: WhisperModelLocation? {
        status == .ready ? location : nil
    }

    @ObservationIgnored
    private let fileManager: FileManager

    @ObservationIgnored
    private var coordinator: DownloadCoordinator?

    init(spec: ModelDownloadSpec, fileManager: FileManager = .default) {
        self.spec = spec
        self.fileManager = fileManager
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        var dir = appSupport
        for component in spec.subdirectory {
            dir = dir.appendingPathComponent(component, isDirectory: true)
        }
        self.modelDirectory = dir
        refreshStatus()
    }

    /// Convenience for tests — explicit directory, skips the Application-Support
    /// lookup.
    init(spec: ModelDownloadSpec, modelDirectory: URL, fileManager: FileManager = .default) {
        self.spec = spec
        self.fileManager = fileManager
        self.modelDirectory = modelDirectory
        refreshStatus()
    }

    /// Re-read on-disk state. Only flips between `.missing` and `.ready`; an
    /// in-flight `.downloading` or sticky `.failed` carries state the disk can't
    /// recover, so those are left alone.
    func refreshStatus() {
        switch status {
        case .downloading, .failed:
            return
        case .missing, .ready:
            break
        }
        status = isReady() ? .ready : .missing
    }

    /// Download every remote file (each verified by size + SHA-256, atomically
    /// moved into place, excluded from iCloud backup), staging bundled assets
    /// alongside. **Throws** on cancellation, network failure, HTTP non-2xx,
    /// byte/hash mismatch, and filesystem failures; also sets `.failed(reason:)`
    /// so observers can render the error UI.
    func download() async throws {
        guard coordinator == nil else { throw StoreError.alreadyDownloading }

        if !spec.bundledFiles.isEmpty {
            do {
                try stageBundledAssets()
            } catch let StoreError.bundledAssetMissing(name) {
                status = .failed(reason: .bundledAssetMissing(name))
                throw StoreError.bundledAssetMissing(name)
            }
        }

        try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        status = .downloading(progress: 0)

        // Byte-weighted overall progress across all remote files (the Parakeet
        // config.json is negligible next to the 2.47 GB weights, but the math is
        // general).
        let totalBytes = spec.remoteFiles.reduce(Int64(0)) { $0 + $1.size }
        var bytesDoneInPriorFiles: Int64 = 0

        for file in spec.remoteFiles {
            let coordinator = DownloadCoordinator()
            self.coordinator = coordinator

            let tempURL: URL
            do {
                tempURL = try await coordinator.download(
                    from: file.url,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in
                            guard let self else { return }
                            if case .downloading = self.status {
                                let overall = totalBytes > 0
                                    ? Double(bytesDoneInPriorFiles + Int64(fraction * Double(file.size)))
                                        / Double(totalBytes)
                                    : fraction
                                self.status = .downloading(progress: overall)
                            }
                        }
                    }
                )
            } catch let DownloadCoordinator.CoordinatorError.unexpectedHTTPStatus(code) {
                self.coordinator = nil
                status = .failed(reason: .server(statusCode: code))
                throw StoreError.unexpectedHTTPStatus(code)
            } catch is CancellationError {
                self.coordinator = nil
                status = .failed(reason: .cancelled)
                throw CancellationError()
            } catch {
                self.coordinator = nil
                status = .failed(reason: .network)
                throw error
            }
            self.coordinator = nil

            do {
                try verifyAndInstall(tempURL: tempURL, file: file)
            } catch let StoreError.integrityCheckFailed(expected, got) {
                try? fileManager.removeItem(at: tempURL)
                status = .failed(reason: .integrityCheckFailed)
                throw StoreError.integrityCheckFailed(expected: expected, got: got)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                status = .failed(reason: .diskWriteFailed)
                throw error
            }

            bytesDoneInPriorFiles += file.size
        }

        status = .ready
    }

    /// Cancel the in-flight download (if any). The download function throws
    /// `CancellationError`. No-op if nothing's running.
    func cancelDownload() {
        coordinator?.cancel()
    }

    /// Remove the downloaded files and any staged bundle assets. Leaves the empty
    /// `modelDirectory` in place (harmless).
    func delete() throws {
        cancelDownload()
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        status = .missing
    }

    // MARK: - Bundled-asset staging

    /// Idempotently copies `spec.bundledFiles` from `Bundle.main` into
    /// `modelDirectory`, always overwriting (bundled files are the source of
    /// truth; an app update may ship new versions). No-op when the spec bundles
    /// nothing (Parakeet).
    func stageBundledAssets() throws {
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        for asset in spec.bundledFiles {
            guard let bundleURL = Bundle.main.url(forResource: asset.name, withExtension: asset.ext) else {
                throw StoreError.bundledAssetMissing(asset.filename)
            }
            let destURL = modelDirectory.appendingPathComponent(asset.filename)
            try? fileManager.removeItem(at: destURL)
            try fileManager.copyItem(at: bundleURL, to: destURL)
        }
    }

    // MARK: - Helpers

    /// Ready ⇔ every remote file is present on disk. (Bundled assets are staged
    /// at download time and not re-checked — they're cheap to restage.)
    private func isReady() -> Bool {
        spec.remoteFiles.allSatisfy {
            fileManager.fileExists(atPath: modelDirectory.appendingPathComponent($0.destFilename).path)
        }
    }

    private func verifyAndInstall(tempURL: URL, file: ModelDownloadSpec.RemoteFile) throws {
        let attrs = try fileManager.attributesOfItem(atPath: tempURL.path)
        if let size = attrs[.size] as? Int64, size != file.size {
            throw StoreError.integrityCheckFailed(
                expected: "size=\(file.size)", got: "size=\(size)")
        }

        let computed = try Self.sha256Hex(of: tempURL)
        guard computed == file.sha256 else {
            throw StoreError.integrityCheckFailed(expected: file.sha256, got: computed)
        }

        let dest = modelDirectory.appendingPathComponent(file.destFilename)
        try? fileManager.removeItem(at: dest)
        try fileManager.moveItem(at: tempURL, to: dest)

        // Exclude from iCloud backup (Apple review guideline for redownloadable
        // content — model files qualify).
        var destMutable = dest
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destMutable.setResourceValues(values)
    }

    /// Streams the file through `CryptoKit.SHA256` in 1 MB chunks — flat peak
    /// memory regardless of file size.
    static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = 1 << 20  // 1 MB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DownloadCoordinator

/// Owns one URLSession + delegate pair for the duration of one file download,
/// wrapping a download task in a checked continuation. Progress callbacks fire
/// from the URLSession delegate queue.
///
/// **Why a custom URLSession (not `.shared`):** the async
/// `URLSession.download(for:delegate:)` only delivers `URLSessionTaskDelegate`
/// callbacks, not the `URLSessionDownloadDelegate.didWriteData(...)` we need for
/// progress; the custom session also lets us `invalidateAndCancel()` to break the
/// session ↔ delegate retain cycle once finished.
///
/// **Resume / retry (§3.4):** large model files stream from CDNs (HF's Xet
/// bridge) that stall mid-transfer — the 2.5 GB Parakeet download hit a `-1001`
/// on a single pause. On a transient failure this re-issues the request up to
/// `maxAttempts` times, **resuming from `NSURLSessionDownloadTaskResumeData`**
/// when the server supports range requests (Xet/S3 does) so a stall doesn't throw
/// away the bytes already on disk, and restarting the file otherwise.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum CoordinatorError: Error {
        case unexpectedHTTPStatus(Int)
    }

    private enum RetryDecision {
        case retry(URLSessionDownloadTask)
        case fail
        case failCancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    /// Temp location we move the system-supplied finished file to, since the
    /// system deletes it the moment our delegate method returns.
    private var preservedTempURL: URL?
    private var originalURL: URL?
    private var remainingAttempts = 0

    /// Re-issue budget for transient failures (resume when possible, else restart).
    private static let maxAttempts = 5

    func download(from url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        // The default 60 s `timeoutIntervalForRequest` (max wait for *more* data)
        // aborts the whole transfer on a single stall — widen it, let the session
        // wait for connectivity, and bound the total with `timeoutIntervalForResource`.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock {
            self.session = session
            self.onProgress = onProgress
            self.originalURL = url
            self.remainingAttempts = Self.maxAttempts
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDownloadTask = lock.withLock {
                    self.continuation = continuation
                    let task = session.downloadTask(with: url)
                    self.task = task
                    return task
                }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            self.remainingAttempts = 0  // a user cancel must not be retried
            return self.task
        }
        task?.cancel()
    }

    private func takeContinuation() -> CheckedContinuation<URL, Error>? {
        lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten written: Int64,
        totalBytesExpectedToWrite total: Int64
    ) {
        guard total > 0 else { return }
        let cb = lock.withLock { onProgress }
        cb?(Double(written) / Double(total))
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` when this returns. Move to a temp path we
        // control so the continuation hand-off can hold it.
        let preserved = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-dl-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: preserved)
            lock.withLock { self.preservedTempURL = preserved }
        } catch {
            let cont = takeContinuation()
            cont?.resume(throwing: error)
            invalidate()
            return
        }

        // Validate HTTP response (permanent failure — not retried).
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let cont = takeContinuation()
            cont?.resume(throwing: CoordinatorError.unexpectedHTTPStatus(http.statusCode))
            invalidate()
            return
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            // Decide retry-vs-fail atomically (and build the next task under lock).
            let decision: RetryDecision = lock.withLock {
                if (error as? URLError)?.code == .cancelled { return .failCancelled }
                guard remainingAttempts > 0, let session, let originalURL else { return .fail }
                remainingAttempts -= 1
                let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let newTask = resumeData.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: originalURL)
                self.task = newTask
                return .retry(newTask)
            }
            switch decision {
            case let .retry(newTask):
                newTask.resume()  // keep the same continuation pending
            case .failCancelled:
                takeContinuation()?.resume(throwing: CancellationError())
                invalidate()
            case .fail:
                takeContinuation()?.resume(throwing: error)
                invalidate()
            }
            return
        }

        let preserved = lock.withLock { preservedTempURL }
        let cont = takeContinuation()
        if let preserved {
            cont?.resume(returning: preserved)
        } else {
            // Shouldn't reach here — didFinishDownloadingTo runs first on success
            // and either set `preserved` or already resumed with an error.
            cont?.resume(throwing: CoordinatorError.unexpectedHTTPStatus(-1))
        }
        invalidate()
    }

    private func invalidate() {
        let s = lock.withLock { () -> URLSession? in
            let s = session
            session = nil
            task = nil
            onProgress = nil
            return s
        }
        s?.invalidateAndCancel()
    }
}
