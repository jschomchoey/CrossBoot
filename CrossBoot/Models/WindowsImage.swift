import Foundation

// Processor architecture as recorded in a WIM image's XML metadata.
enum WindowsArchitecture: Int, Hashable {
    case x86 = 0
    case arm = 5
    case x64 = 9
    case arm64 = 12

    var name: String {
        switch self {
        case .x86: return "x86"
        case .arm: return "ARM"
        case .x64: return "x64"
        case .arm64: return "ARM64"
        }
    }

    // processorArchitecture in an answer file. Setup silently ignores a
    // component whose architecture does not match the WinPE running it, which
    // is how a bypass can appear to be configured and do nothing.
    var unattendName: String {
        switch self {
        case .x86: return "x86"
        case .arm: return "arm"
        case .x64: return "amd64"
        case .arm64: return "arm64"
        }
    }
}

// One installable edition inside an ISO's install.wim or install.esd.
struct WindowsImage: Hashable {
    // 1-based index within its own WIM, which is how wimlib addresses it.
    let index: Int
    let name: String
    let architecture: WindowsArchitecture?
    let build: Int
    // Uncompressed size, used to weight merge progress across images.
    let totalBytes: Int64

    // Merged media routinely carries the same edition name twice, so every
    // entry in the setup menu is labelled with the build it came from.
    var mergedName: String {
        build > 0 ? "\(name) (Build \(build))" : name
    }
}

// Where an ISO keeps its installable images, and how big that file is.
struct InstallImage: Hashable {
    // Relative to the ISO root, spelled as the ISO actually spells it.
    let relativePath: String
    let sizeBytes: Int64

    var isSolid: Bool {
        relativePath.lowercased().hasSuffix(".esd")
    }
}
