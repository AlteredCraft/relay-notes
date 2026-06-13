import CryptoKit
import Foundation
import Observation

/// Owns the on-disk presence of the Whisper model bundle and the URLSession
/// download that brings the weights in.
///
/// Files live in `Application Support/whisper/small.en/`:
///   - `weights.safetensors` — **downloaded** from HuggingFace (~481 MB FP16).
///   - `config.json` / `gpt2.tiktoken` / `mel_filters.safetensors` — **staged
///     from the app bundle** (small, version-locked with the Swift port).
///
/// **Why bundle the small files instead of downloading all four:** they total
/// ~2 MB, change only when the Swift port's expectations change (i.e. with
/// app updates), and including them in the download manifest would add three
/// integrity-check surfaces for negligible disk-footprint win.
///
/// **Why HuggingFace direct (not GitHub Releases or self-hosted):**
/// `mlx-community/whisper-small.en-fp16` already ships `model.safetensors` in
/// the MLX-native tensor naming our `WhisperModel.load(from:)` consumes — same
/// 481 MB FP16 file we'd otherwise be hosting ourselves. Pinning the URL to a
/// commit SHA makes the file content immutable; if HF ever removes the asset,
/// the download fails predictably and we can swap to a mirror.
@MainActor
@Observable
final class WhisperModelStore {

    enum Status: Equatable {
        case missing
        case downloading(progress: Double)
        case ready
        case failed(reason: FailureReason)
    }

    /// Granular failure cases — surfaced to the user as a generic "please try
    /// again" message at the UI layer; the specific reason is for logs and
    /// for the retry UX (e.g. integrity failure should clean the partial file
    /// before allowing retry).
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

    /// Pinned to a specific commit on `mlx-community/whisper-small.en-fp16` so
    /// the file content at this URL is immutable. Bump alongside `expectedSHA256`
    /// + `expectedSize` if/when we revisit the weights.
    nonisolated static let downloadURL = URL(string:
        "https://huggingface.co/mlx-community/whisper-small.en-fp16/resolve/"
        + "f8ff44ec66c4b1748fb2e3eb13b3b521a0bdfea8/model.safetensors"
    )!

    /// SHA-256 of the pinned `model.safetensors` (Git LFS `oid` from HF's tree
    /// API). Computed once at integration time; load is refused if a fresh
    /// download doesn't hash to this value.
    nonisolated static let expectedSHA256 =
        "36375db96d2900eceb62ed9fe43dec23854266adc6d7ad827f661b81fb0893b4"

    /// Exact byte count of the pinned file. Lets us early-fail before computing
    /// the SHA on a mid-truncated download.
    nonisolated static let expectedSize: Int64 = 481_213_970

    /// Files staged from `Bundle.main` into the model directory at download
    /// time. The 4th file (weights) is downloaded separately.
    fileprivate static let bundledAssets: [(name: String, ext: String)] = [
        ("config", "json"),
        ("gpt2", "tiktoken"),
        ("mel_filters", "safetensors"),
    ]

    private(set) var status: Status = .missing

    /// The on-disk directory that holds the model bundle. Stable for the life
    /// of the process; `WhisperModelLocation.directory(modelDirectory)` is the
    /// load-bearing thing the future cached transcriber (T1.2c) reads from.
    let modelDirectory: URL

    /// Convenience for the consumer side — once `status == .ready`, hand this
    /// to `WhisperMLXTranscriber`.
    var location: WhisperModelLocation { .directory(modelDirectory) }

    /// The location consumers should load from right now, or `nil` when the
    /// downloaded model isn't usable (missing / mid-download / failed).
    /// `WhisperMLXTranscriber` reads this per call and falls back to
    /// `.bundled` on `nil`. Lives here (not on the consumer) so the
    /// `status == .ready` comparison stays on the main actor — `Status` is
    /// implicitly `@MainActor` as a nested type.
    var activeLocation: WhisperModelLocation? {
        status == .ready ? location : nil
    }

    @ObservationIgnored
    private let fileManager: FileManager

    @ObservationIgnored
    private var coordinator: DownloadCoordinator?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        self.modelDirectory = appSupport
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent("small.en", isDirectory: true)
        refreshStatus()
    }

    /// Convenience init for tests — explicit directory, skips the
    /// Application-Support lookup.
    init(modelDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.modelDirectory = modelDirectory
        refreshStatus()
    }

    /// Re-read the on-disk state. Called by `init`, after `download()`,
    /// after `delete()`, and on demand from the Settings sheet if the user
    /// suspects an external change.
    func refreshStatus() {
        // We don't downgrade an in-flight `.downloading` or a sticky
        // `.failed` to whatever's on disk — those carry state the disk alone
        // can't recover. Only flip between `.missing` and `.ready`.
        switch status {
        case .downloading, .failed:
            return
        case .missing, .ready:
            break
        }
        status = isWeightsPresent() ? .ready : .missing
    }

    /// Download the weights, verify SHA-256, atomically move into place,
    /// exclude from iCloud backup, stage the bundled assets alongside.
    /// **Throws** on cancellation, network failure, HTTP non-200, byte-count
    /// mismatch, hash mismatch, and filesystem failures. Status is also set to
    /// `.failed(reason:)` so observers can render the error UI.
    func download() async throws {
        guard coordinator == nil else { throw StoreError.alreadyDownloading }

        do {
            try stageBundledAssets()
        } catch let StoreError.bundledAssetMissing(name) {
            status = .failed(reason: .bundledAssetMissing(name))
            throw StoreError.bundledAssetMissing(name)
        }

        status = .downloading(progress: 0)

        let coordinator = DownloadCoordinator()
        self.coordinator = coordinator
        defer { self.coordinator = nil }

        let tempURL: URL
        do {
            tempURL = try await coordinator.download(
                from: Self.downloadURL,
                onProgress: { [weak self] fraction in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .downloading = self.status {
                            self.status = .downloading(progress: fraction)
                        }
                    }
                }
            )
        } catch let DownloadCoordinator.CoordinatorError.unexpectedHTTPStatus(code) {
            status = .failed(reason: .server(statusCode: code))
            throw StoreError.unexpectedHTTPStatus(code)
        } catch is CancellationError {
            status = .failed(reason: .cancelled)
            throw CancellationError()
        } catch {
            status = .failed(reason: .network)
            throw error
        }

        do {
            try verifyAndInstall(tempURL: tempURL)
        } catch let StoreError.integrityCheckFailed(expected, got) {
            try? fileManager.removeItem(at: tempURL)
            status = .failed(reason: .integrityCheckFailed)
            throw StoreError.integrityCheckFailed(expected: expected, got: got)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            status = .failed(reason: .diskWriteFailed)
            throw error
        }

        status = .ready
    }

    /// Cancel the in-flight download (if any). The download function will
    /// throw `CancellationError`. No-op if no download is running.
    func cancelDownload() {
        coordinator?.cancel()
    }

    /// Remove the downloaded weights and any staged bundle assets — frees the
    /// ~481 MB on disk. Leaves the empty `modelDirectory` in place (harmless).
    func delete() throws {
        cancelDownload()
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        status = .missing
    }

    // MARK: - Bundled-asset staging

    /// Idempotently copies `config.json`, `gpt2.tiktoken`, `mel_filters.safetensors`
    /// from the app bundle into `modelDirectory`. Always overwrites — bundled
    /// files are the source of truth and an app update may have shipped new
    /// versions. Cheap (~2 MB total).
    func stageBundledAssets() throws {
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        for (name, ext) in Self.bundledAssets {
            guard let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) else {
                throw StoreError.bundledAssetMissing("\(name).\(ext)")
            }
            let destURL = modelDirectory.appendingPathComponent("\(name).\(ext)")
            try? fileManager.removeItem(at: destURL)
            try fileManager.copyItem(at: bundleURL, to: destURL)
        }
    }

    // MARK: - Helpers

    private func isWeightsPresent() -> Bool {
        let weightsFile = modelDirectory.appendingPathComponent("weights.safetensors")
        return fileManager.fileExists(atPath: weightsFile.path)
    }

    private func verifyAndInstall(tempURL: URL) throws {
        let attrs = try fileManager.attributesOfItem(atPath: tempURL.path)
        if let size = attrs[.size] as? Int64, size != Self.expectedSize {
            throw StoreError.integrityCheckFailed(
                expected: "size=\(Self.expectedSize)",
                got: "size=\(size)"
            )
        }

        let computed = try Self.sha256Hex(of: tempURL)
        guard computed == Self.expectedSHA256 else {
            throw StoreError.integrityCheckFailed(
                expected: Self.expectedSHA256,
                got: computed
            )
        }

        let weightsFile = modelDirectory.appendingPathComponent("weights.safetensors")
        try? fileManager.removeItem(at: weightsFile)
        try fileManager.moveItem(at: tempURL, to: weightsFile)

        // Exclude from iCloud backup. Required by Apple's review guidelines
        // for content that's redownloadable (model files qualify).
        var weightsFileMutable = weightsFile
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try weightsFileMutable.setResourceValues(values)
    }

    /// Streams the file through `CryptoKit.SHA256`. Reads 1 MB chunks — small
    /// enough to keep peak memory flat, large enough that I/O dominates over
    /// hashing overhead for a ~481 MB file.
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

/// Owns one URLSession + delegate pair for the duration of one download.
/// The `download(from:onProgress:)` async function wraps a download task in a
/// checked continuation; progress callbacks fire from the URLSession delegate
/// queue and are forwarded to `onProgress`.
///
/// **Why a custom URLSession (not `.shared`):** the async
/// `URLSession.download(for:delegate:)` API only delivers `URLSessionTaskDelegate`
/// callbacks, not the `URLSessionDownloadDelegate.didWriteData(...)` we need for
/// progress. The custom session also lets us call `invalidateAndCancel()` after
/// the download finishes to break the URLSession ↔ delegate retain cycle.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum CoordinatorError: Error {
        case unexpectedHTTPStatus(Int)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    /// Temp location we move the system-supplied finished-download file to,
    /// since the system deletes it the moment our delegate method returns.
    private var preservedTempURL: URL?

    func download(from url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        // Large model files (Whisper ~481 MB, Parakeet ~2.5 GB) download from CDNs
        // (e.g. HuggingFace's Xet bridge) that can stall mid-transfer. The default
        // 60 s `timeoutIntervalForRequest` (max wait for *more* data) aborts the
        // whole transfer on a single stall — observed as a -1001 timeout on the
        // 2.5 GB Parakeet file. Widen it and let the session wait for connectivity
        // rather than failing fast; `timeoutIntervalForResource` bounds the total.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock {
            self.session = session
            self.onProgress = onProgress
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
        let task = lock.withLock { self.task }
        task?.cancel()
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
        // The system deletes `location` when this returns. Move to a temp
        // path under our control so the continuation hand-off can hold it.
        let preserved = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-dl-\(UUID().uuidString).safetensors")
        do {
            try FileManager.default.moveItem(at: location, to: preserved)
            lock.withLock { self.preservedTempURL = preserved }
        } catch {
            // Falls through to didCompleteWithError — but if no error gets
            // surfaced, we need to fail the continuation here.
            let cont = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                let c = continuation
                continuation = nil
                return c
            }
            cont?.resume(throwing: error)
            invalidate()
            return
        }

        // Validate HTTP response. The task's response is set by now.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let cont = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                let c = continuation
                continuation = nil
                return c
            }
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
        let (cont, preserved) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?) in
            let c = continuation
            continuation = nil
            return (c, preservedTempURL)
        }

        if let error {
            // URLError.cancelled → CancellationError so the caller can pattern-match.
            if (error as? URLError)?.code == .cancelled {
                cont?.resume(throwing: CancellationError())
            } else {
                cont?.resume(throwing: error)
            }
            invalidate()
            return
        }

        if let preserved {
            cont?.resume(returning: preserved)
        } else {
            // Shouldn't reach here — didFinishDownloadingTo runs before
            // didCompleteWithError on success, and either sets `preserved`
            // or already resumed the continuation with an error.
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
