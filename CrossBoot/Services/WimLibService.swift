import Foundation

/// Handles WIM file splitting using wimlib-imagex
actor WimLibService {
    static let shared = WimLibService()
    
    private init() {}
    
    /// Get path to bundled wimlib-imagex binary
    private var wimlibPath: String {
        Bundle.main.path(forResource: "wimlib-imagex", ofType: nil) ?? "/usr/local/bin/wimlib-imagex"
    }
    
    /// Split a large WIM file into smaller SWM files
    /// - Parameters:
    ///   - wimPath: Path to the source install.wim
    ///   - onProgress: Progress callback (0-100)
    /// - Returns: URL to temp directory containing split files
    func splitWIM(_ wimPath: String, onProgress: @escaping (Int) -> Void) async throws -> URL {
        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let outputPath = tempDir.appendingPathComponent("install.swm").path
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: wimlibPath)
            process.arguments = ["split", wimPath, outputPath, "3800"]
            process.standardOutput = pipe
            process.standardError = pipe
            
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                
                // Parse progress percentage from wimlib output
                if let range = output.range(of: "(\\d+)%", options: .regularExpression),
                   let percent = Int(output[range].dropLast()) {
                    Task { @MainActor in
                        onProgress(percent)
                    }
                }
            }
            
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: tempDir)
                } else {
                    try? FileManager.default.removeItem(at: tempDir)
                    continuation.resume(throwing: WimLibError.splitFailed(Int(proc.terminationStatus)))
                }
            }
            
            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                continuation.resume(throwing: error)
            }
        }
    }
}

enum WimLibError: LocalizedError {
    case splitFailed(Int)
    case binaryNotFound
    
    var errorDescription: String? {
        switch self {
        case .splitFailed(let code): return "WIM split failed with code \(code)"
        case .binaryNotFound: return "wimlib-imagex binary not found"
        }
    }
}
