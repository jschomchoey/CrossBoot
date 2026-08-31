import Foundation

// Current stage of the bootable USB creation process
enum ProcessStage: Equatable {
    case idle
    case formatting
    case analyzing
    case merging
    case rebuilding
    case splitting
    case copying
    // macOS runs: fetching the installer, waiting on the authorization prompt,
    // unpacking it, and letting createinstallmedia write the drive.
    case downloading
    case authorizing
    case preparingInstaller
    case writingInstaller
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
        case .merging: return "Merging Windows versions"
        case .rebuilding: return "Rewriting the install image"
        case .splitting: return "Splitting install.wim"
        case .copying: return "Copying files"
        case .downloading: return "Downloading macOS"
        case .authorizing: return "Waiting for your password in Terminal"
        case .preparingInstaller: return "Preparing the macOS installer"
        case .writingInstaller: return "Writing the macOS installer"
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
        case .formatting, .analyzing, .merging, .rebuilding, .splitting, .copying,
             .downloading, .authorizing, .preparingInstaller, .writingInstaller, .aborting:
            return true
        }
    }

    // Once createinstallmedia is running the drive is being written by a root
    // process this app cannot signal mid-step, so stopping has to wait for it.
    var isCancellable: Bool {
        switch stage {
        case .authorizing, .aborting:
            return false
        default:
            return isProcessing
        }
    }
}
