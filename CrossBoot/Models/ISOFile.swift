import Foundation

/// Represents a selected ISO file
struct ISOFile {
    let url: URL
    let name: String
    let sizeBytes: Int64
    
    var sizeFormatted: String {
        let gb = Double(sizeBytes) / (1024 * 1024 * 1024)
        return String(format: "%.2f GB", gb)
    }
    
    init(url: URL) throws {
        self.url = url
        self.name = url.lastPathComponent
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.sizeBytes = attributes[.size] as? Int64 ?? 0
    }
}
