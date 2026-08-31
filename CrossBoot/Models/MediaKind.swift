import Foundation

// Which kind of install media a run produces. The two kinds share a drive, a
// progress bar and an action bar; everything above that differs.
enum MediaKind: String, CaseIterable, Identifiable, Hashable {
    case windows
    case macOS

    var id: String { rawValue }

    var name: String {
        switch self {
        case .windows: return "Windows"
        case .macOS: return "macOS"
        }
    }
}
