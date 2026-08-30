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

    // Short line shown beside the progress bar while a run is in flight.
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .formatting: return "Formatting the drive"
        case .analyzing: return "Analyzing the ISO"
        case .splitting: return "Splitting install.wim"
        case .copying: return "Copying files"
        case .aborting: return "Stopping"
        case .done: return "Done"
        case .aborted: return "Stopped"
        case .error(let message): return message
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
        case .formatting, .analyzing, .splitting, .copying, .aborting:
            return true
        }
    }
}
