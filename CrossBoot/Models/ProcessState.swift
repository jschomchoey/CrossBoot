import Foundation

// Current stage of the bootable USB creation process
enum ProcessStage: Equatable {
    case idle
    case formatting
    case analyzing
    case splitting
    case copying
    case aborting
    case done
    case aborted
    case error(String)
    
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .formatting: return "Formatting USB..."
        case .analyzing: return "Analyzing ISO..."
        case .splitting: return "Splitting WIM file..."
        case .copying: return "Copying files..."
        case .aborting: return "Aborting..."
        case .done: return "Done. USB is ready."
        case .aborted: return "Process aborted."
        case .error(let message): return "Error: \(message)"
        }
    }
}

// Tracks the state of the ongoing process
struct ProcessState {
    var stage: ProcessStage = .idle
    var progress: Double = 0
    var currentFile: String = ""
    
    // A failure leaves no meaningful progress behind, so it always resets.
    static func failed(_ message: String) -> ProcessState {
        ProcessState(stage: .error(message), progress: 0)
    }

    var isProcessing: Bool {
        switch stage {
        case .idle, .done, .aborted, .error:
            return false
        default:
            return true
        }
    }
}
