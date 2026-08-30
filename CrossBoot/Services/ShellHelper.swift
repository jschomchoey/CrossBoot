import Foundation

// Runs external executables directly.
//
// Commands are never passed through a shell: arguments go to the process as a
// literal argv, so paths containing spaces, quotes or `$(...)` are handed to the
// tool verbatim instead of being expanded.
enum ShellHelper {

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            // Both pipes must be drained while the child runs. Reading only after
            // termination deadlocks as soon as the child fills the pipe buffer.
            let captured = CapturedOutput()
            let readers = DispatchGroup()

            for (pipe, stream) in [(outputPipe, CapturedOutput.Stream.output), (errorPipe, .error)] {
                readers.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    captured.store(pipe.fileHandleForReading.readDataToEndOfFile(), for: stream)
                    readers.leave()
                }
            }

            process.terminationHandler = { process in
                let status = process.terminationStatus
                readers.notify(queue: .global(qos: .userInitiated)) {
                    guard status == 0 else {
                        continuation.resume(throwing: ShellError.commandFailed(
                            command: (executable as NSString).lastPathComponent,
                            status: status,
                            message: captured.text(for: .error)
                        ))
                        return
                    }
                    continuation.resume(returning: captured.text(for: .output))
                }
            }

            do {
                try process.run()
            } catch {
                // The child never launched, so it will not close the write ends
                // the readers are blocked on.
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }
}

// Output arrives on two reader threads and is read back on a third.
private final class CapturedOutput: @unchecked Sendable {
    enum Stream {
        case output
        case error
    }

    private let lock = NSLock()
    private var streams: [Stream: Data] = [:]

    func store(_ data: Data, for stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        streams[stream] = data
    }

    func text(for stream: Stream) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: streams[stream] ?? Data(), as: UTF8.self)
    }
}

enum ShellError: LocalizedError {
    case commandFailed(command: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let status, let message):
            // The tool's own message is far more useful than an exit code.
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) failed with status \(status)" : detail
        }
    }
}
