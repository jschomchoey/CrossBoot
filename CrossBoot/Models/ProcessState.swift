import Foundation

/// Current stage of the bootable USB creation process
enum ProcessStage: Equatable {
    case idle
    case formatting
    case analyzing
    case splitting
    case copying
    case done
    case error(String)
    
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .formatting: return "Formatting USB..."
        case .analyzing: return "Analyzing ISO..."
        case .splitting: return "Splitting WIM file..."
        case .copying: return "Copying files..."
        case .done: return "Done. USB is ready."
        case .error(let message): return "Error: \(message)"
        }
    }
}

/// Tracks the state of the ongoing process
struct ProcessState {
    var stage: ProcessStage = .idle
    var progress: Double = 0
    var currentFile: String = ""
    
    var isProcessing: Bool {
        switch stage {
        case .idle, .done, .error:
            return false
        default:
            return true
        }
    }
}
