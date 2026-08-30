import Foundation

// A Windows ISO the user picked, together with what an inspection pass found
// inside it. Everything after `sizeBytes` is empty until the ISO is analyzed.
struct ISOFile: Identifiable, Hashable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let installImage: InstallImage?
    let images: [WindowsImage]
    // Whether the ISO carries its own UEFI boot loader, which is what makes it
    // usable as the base of the drive.
    let hasBootLoader: Bool

    var id: URL { url }

    var sizeFormatted: String {
        sizeBytes.formattedSize
    }

    // Every image in one ISO shares an architecture; setup cannot mix them.
    var architecture: WindowsArchitecture? {
        images.compactMap(\.architecture).first
    }

    var newestBuild: Int {
        images.map(\.build).max() ?? 0
    }

    // One line under the file name in the source list.
    var summary: String {
        guard !images.isEmpty else {
            return installImage == nil ? "No Windows install image found" : "\(images.count) editions"
        }

        var parts: [String] = []
        if let architecture { parts.append(architecture.name) }
        if newestBuild > 0 { parts.append("Build \(newestBuild)") }
        parts.append(images.count == 1 ? "1 edition" : "\(images.count) editions")
        parts.append(sizeFormatted)
        return parts.joined(separator: " · ")
    }

    init(
        url: URL,
        installImage: InstallImage? = nil,
        images: [WindowsImage] = [],
        hasBootLoader: Bool = false
    ) throws {
        self.url = url
        self.name = url.lastPathComponent
        self.installImage = installImage
        self.images = images
        self.hasBootLoader = hasBootLoader

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.sizeBytes = attributes[.size] as? Int64 ?? 0
    }
}
