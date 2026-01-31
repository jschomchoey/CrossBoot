import Foundation

/// Utility for running shell commands
enum ShellHelper {
    
    /// Run a shell command and return output
    @discardableResult
    static func run(_ command: String, asAdmin: Bool = false) async throws -> String {
        if asAdmin {
            return try await runWithAdminPrivileges(command)
        }
        
        let process = Process()
        let pipe = Pipe()
        
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
            throw ShellError.commandFailed(output)
        }
        
        return output
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
