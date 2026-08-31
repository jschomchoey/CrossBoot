import Foundation

// Downloads an InstallAssistant package from Apple.
//
// These run from 12 GB to 18 GB, so the transfer is handed to a download task
// that streams straight to disk rather than being held in memory, and the byte
// count the catalog promised is checked before anything is done with the file.
actor InstallerDownloader {
    static let shared = InstallerDownloader()

    private init() {}

    func download(
        from url: URL,
        expecting expectedBytes: Int64,
        to destination: URL,
        onProgress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        try Task.checkCancellation()

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let received = attributes[.size] as? Int64 ?? 0

        // The catalog's byte count is the only integrity check Apple publishes
        // for these packages, so a short or padded file has to fail here rather
        // than halfway through expanding it as root.
        guard expectedBytes <= 0 || received == expectedBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw DownloadError.sizeMismatch(expected: expectedBytes, received: received)
        }
    }
}

// URLSession reports progress on its own queue and finishes on another, so the
// continuation is guarded rather than assumed to be touched once.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable @MainActor (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    // A download of this size reports progress tens of thousands of times;
    // only a change the progress bar could show is worth waking the UI for.
    private var reportedPercent = -1

    init(destination: URL, onProgress: @escaping @Sendable @MainActor (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 1000)

        lock.lock()
        let changed = percent != reportedPercent
        if changed { reportedPercent = percent }
        lock.unlock()

        guard changed else { return }

        let value = Double(percent) / 10
        let report = onProgress
        Task { @MainActor in report(value) }
    }

    // The temporary file is gone as soon as this returns, so the move cannot be
    // deferred to the completion callback.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            finish(.failure(DownloadError.refused(status: status)))
            return
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}

enum DownloadError: LocalizedError, Equatable {
    case refused(status: Int)
    case sizeMismatch(expected: Int64, received: Int64)

    var errorDescription: String? {
        switch self {
        case .refused(let status):
            return "Apple's download server answered with status \(status). Nothing was erased."
        case .sizeMismatch(let expected, let received):
            return """
            The download is \(received.formattedSize) but Apple lists \(expected.formattedSize). \
            It was discarded and nothing was erased.
            """
        }
    }
}
