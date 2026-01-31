import Foundation

/// Represents a selected ISO file
struct ISOFile {
    let url: URL
    let name: String
    let sizeBytes: Int64
    
    var sizeFormatted: String {
        // Use decimal (1000) to match macOS Finder display
        let gb = Double(sizeBytes) / (1000 * 1000 * 1000)
        return String(format: "%.2f GB", gb)
    }
    
    init(url: URL) throws {
        self.url = url
        self.name = url.lastPathComponent
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.sizeBytes = attributes[.size] as? Int64 ?? 0
    }
}
