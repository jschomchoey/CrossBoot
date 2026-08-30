import Foundation

// Inspects, merges and splits Windows install images with wimlib-imagex.
actor WimLibService {
    static let shared = WimLibService()

    private init() {}

    // FAT32 caps a single file at 4 GiB; the margin leaves room for the
    // per-part headers wimlib writes.
    private static let partSizeMB = 3800

    static let fat32FileLimit: Int64 = 4 * 1024 * 1024 * 1024

    // Compression of a merged image. Exporting into the format that already
    // holds most of the bytes lets wimlib copy blobs across instead of
    // recompressing them, which is the difference between minutes and hours.
    enum Compression {
        case lzx
        case solid

        var argument: String {
            switch self {
            case .lzx: return "--compress=LZX"
            case .solid: return "--solid"
            }
        }
    }

    // Read an image list out of a WIM/ESD without unpacking it.
    func inspectImages(at wimPath: String) async throws -> [WindowsImage] {
        let xmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-xml-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: xmlURL) }

        try await ShellHelper.run(try Self.binaryPath(), ["info", wimPath, "--extract-xml", xmlURL.path])

        return try WimXMLParser.images(from: try Data(contentsOf: xmlURL))
    }

    // Append one source image to `destination`, creating it on the first call.
    // Only the first export decides the compression; later ones must match, so
    // the same value has to be passed every time.
    func export(
        image index: Int,
        from wimPath: String,
        to destination: URL,
        named name: String,
        compression: Compression,
        onProgress: @escaping @Sendable @MainActor (Int) -> Void
    ) async throws {
        try await run(
            ["export", wimPath, String(index), destination.path, name, compression.argument],
            operation: "Merging install images",
            onProgress: onProgress
        )
    }

    // Split a WIM into install.swm, install2.swm ... inside `outputDirectory`.
    func splitWIM(
        _ wimPath: String,
        into outputDirectory: URL,
        onProgress: @escaping @Sendable @MainActor (Int) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        try await run(
            ["split", wimPath, outputDirectory.appendingPathComponent("install.swm").path, String(Self.partSizeMB)],
            operation: "Splitting install.wim",
            onProgress: onProgress
        )
    }

    private static func binaryPath() throws -> String {
        guard let path = Bundle.main.path(forResource: "wimlib-imagex", ofType: nil) else {
            throw WimLibError.binaryNotFound
        }

        return path
    }

    private func run(
        _ arguments: [String],
        operation: String,
        onProgress: @escaping @Sendable @MainActor (Int) -> Void
    ) async throws {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: try Self.binaryPath())
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        // wimlib reports progress on the same stream as its diagnostics, so the
        // tail is kept: an exit code alone does not say what went wrong.
        let transcript = OutputTail()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            transcript.append(output)

            // A chunk can hold several updates; the last one is the current state.
            if let match = output.matches(of: /(\d+)%/).last, let percent = Int(match.1) {
                Task { @MainActor in
                    onProgress(percent)
                }
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil

                    switch process.terminationStatus {
                    case 0:
                        continuation.resume()
                    case 15, 9:
                        // SIGTERM or SIGKILL - the run was cancelled.
                        continuation.resume(throwing: CancellationError())
                    case let status:
                        continuation.resume(throwing: WimLibError.commandFailed(
                            operation: operation,
                            status: Int(status),
                            message: transcript.text
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

// The last few KB of a tool's output, collected on the pipe's reader thread and
// read back on whichever thread reports the failure.
private final class OutputTail: @unchecked Sendable {
    private static let limit = 4096

    private let lock = NSLock()
    private var buffer = ""

    func append(_ output: String) {
        lock.lock()
        defer { lock.unlock() }

        buffer += output
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }

        // Progress lines are rewritten in place with no newline, so the useful
        // part of a failure is whatever follows the last carriage return.
        return buffer
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("% done") && !$0.contains("% written") }
            .suffix(4)
            .joined(separator: " ")
    }
}

enum WimLibError: LocalizedError {
    case binaryNotFound
    case unreadableMetadata
    case commandFailed(operation: String, status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "wimlib-imagex binary not found"
        case .unreadableMetadata:
            return "The install image has unreadable metadata"
        case .commandFailed(let operation, let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(operation) failed with code \(status)" : "\(operation) failed: \(detail)"
        }
    }
}
