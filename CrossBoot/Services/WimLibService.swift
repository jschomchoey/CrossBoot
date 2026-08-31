import Foundation

// Inspects, merges and splits Windows install images with wimlib-imagex.
actor WimLibService {
    static let shared = WimLibService()

    private init() {}

    // FAT32 caps a single file at 4 GiB; the margin leaves room for the
    // per-part headers wimlib writes.
    private static let partSizeMB = 3800

    static let fat32FileLimit: Int64 = 4 * 1024 * 1024 * 1024

    // What an export writes, and under which name.
    enum ImageSelection {
        // Every image in the source, keeping the names it already has.
        case all
        case one(index: Int, name: String)
    }

    // What an inspection pass learned about a WIM without unpacking it.
    struct Inspection {
        let compression: WimCompression
        let images: [WindowsImage]
    }

    func inspect(at wimPath: String) async throws -> Inspection {
        let xmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-xml-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: xmlURL) }

        let binary = try Self.binaryPath()

        // --extract-xml writes the image list to a file and prints nothing, so
        // the compression takes a second pass over the same header.
        try await ShellHelper.run(binary, ["info", wimPath, "--extract-xml", xmlURL.path])
        let header = try await ShellHelper.run(binary, ["info", wimPath])

        return Inspection(
            compression: Self.compression(inHeader: header),
            images: try WimXMLParser.images(from: try Data(contentsOf: xmlURL))
        )
    }

    static func compression(inHeader header: String) -> WimCompression {
        let value = header
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("Compression:") }?
            .dropFirst("Compression:".count)

        return WimCompression(reported: String(value ?? ""))
    }

    // Append source images to `destination`, creating it on the first call.
    // Only the first export decides the compression; later ones must match, so
    // the same value has to be passed every time.
    func export(
        _ selection: ImageSelection,
        from wimPath: String,
        to destination: URL,
        compression: WimCompression,
        onProgress: @escaping @Sendable @MainActor (Int) -> Void
    ) async throws {
        // wimlib takes the destination before the new name: SRC IMAGE DEST NAME.
        var arguments = ["export", wimPath]
        switch selection {
        case .all:
            arguments += ["all", destination.path]
        case .one(let index, let name):
            arguments += [String(index), destination.path, name]
        }
        arguments.append(compression.exportArgument)

        try await run(
            arguments,
            operation: "Rewriting the install image",
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
