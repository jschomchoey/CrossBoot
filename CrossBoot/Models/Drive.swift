import Foundation

/// Represents a removable USB drive
struct Drive: Identifiable, Hashable {
    let id: String           // e.g., "disk2"
    let device: String       // e.g., "/dev/disk2"
    let name: String         // e.g., "SanDisk Ultra"
    let size: Int64
    
    var sizeFormatted: String {
        let gb = Double(size) / 1_000_000_000
        return String(format: "%.2f GB", gb)
    }
}
