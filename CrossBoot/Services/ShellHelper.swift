import Foundation

/// Utility for running shell commands
enum ShellHelper {
    
    /// Run a shell command and return output
    static func run(_ command: String, asAdmin: Bool = false) async throws -> String {
        if asAdmin {
            return try await runWithAdminPrivileges(command)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            
            process.standardOutput = pipe
            process.standardError = pipe
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: ShellError.commandFailed(output))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Run command with admin privileges using AppleScript
    private static func runWithAdminPrivileges(_ command: String) async throws -> String {
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        do shell script "\(escapedCommand)" with administrator privileges
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error = error {
                throw ShellError.adminFailed(error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error")
            }
            return result.stringValue ?? ""
        }
        throw ShellError.scriptCreationFailed
    }
}

enum ShellError: LocalizedError {
    case commandFailed(String)
    case adminFailed(String)
    case scriptCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .commandFailed(let output): return "Command failed: \(output)"
        case .adminFailed(let message): return "Admin command failed: \(message)"
        case .scriptCreationFailed: return "Failed to create AppleScript"
        }
    }
}
