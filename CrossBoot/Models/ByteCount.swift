import Foundation

extension Int64 {
    // Drives and ISO images are both quoted in decimal units, matching the
    // capacity printed on the hardware.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
