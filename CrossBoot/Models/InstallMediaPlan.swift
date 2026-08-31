import Foundation

// How a set of ISOs becomes one bootable drive.
//
// Secure Boot survives because the boot chain is never rebuilt: one ISO - the
// newest - supplies bootmgfw.efi, boot.wim and setup verbatim, and they stay
// Microsoft-signed. The other ISOs contribute only install images, which setup
// reads as data and firmware never verifies. No shim, no key enrollment.
struct InstallMediaPlan {
    enum Mode {
        // One ISO: copied as it is, exactly as CrossBoot has always done.
        case single(ISOFile)
        // Several ISOs: base supplies the boot files, groups supply the images.
        case merged(base: ISOFile, groups: [SourceGroup], compression: WimLibService.Compression)
    }

    // The images taken from one ISO, kept together so the ISO is mounted once.
    struct SourceGroup: Hashable {
        let source: ISOFile
        let images: [PlannedImage]
    }

    struct PlannedImage: Hashable {
        let index: Int
        let name: String
        let totalBytes: Int64
    }

    let mode: Mode

    // Every ISO the run needs, in the order it will reach them.
    let sources: [ISOFile]

    var base: ISOFile {
        switch mode {
        case .single(let iso): return iso
        case .merged(let base, _, _): return base
        }
    }

    // Every source shares one architecture, so the base speaks for the drive.
    // Media with no readable image metadata is assumed x64, which is what
    // CrossBoot wrote for every drive before it read metadata at all.
    var architecture: WindowsArchitecture {
        base.architecture ?? sources.compactMap(\.architecture).first ?? .x64
    }

    var plannedImages: [PlannedImage] {
        switch mode {
        case .single: return []
        case .merged(_, let groups, _): return groups.flatMap(\.images)
        }
    }

    // An upper bound on what the drive has to hold: the base ISO without its own
    // install image, plus every install image being merged in. Deduplication
    // between images can only make the result smaller.
    var estimatedDriveBytes: Int64 {
        let baseTree = base.sizeBytes - (base.installImage?.sizeBytes ?? 0)

        switch mode {
        case .single(let iso):
            return iso.sizeBytes
        case .merged(_, let groups, _):
            return baseTree + groups.reduce(0) { $0 + ($1.source.installImage?.sizeBytes ?? 0) }
        }
    }

    // Peak scratch space: the merged image, plus the split parts written beside
    // it before it is deleted.
    var estimatedTemporaryBytes: Int64 {
        switch mode {
        case .single(let iso):
            // Only the split parts, and only when the image is too big for FAT32.
            let image = iso.installImage
            guard let image, image.sizeBytes > WimLibService.fat32FileLimit else { return 0 }
            return image.sizeBytes
        case .merged(_, let groups, _):
            let merged = groups.reduce(0) { $0 + ($1.source.installImage?.sizeBytes ?? 0) }
            return merged * 2
        }
    }

    static func make(from isoFiles: [ISOFile]) throws -> InstallMediaPlan {
        guard !isoFiles.isEmpty else {
            throw MediaPlanError.noSources
        }

        if isoFiles.count == 1, let only = isoFiles.first {
            return InstallMediaPlan(mode: .single(only), sources: [only])
        }

        let architectures = Set(isoFiles.compactMap(\.architecture))
        guard architectures.count <= 1 else {
            throw MediaPlanError.mixedArchitectures(architectures.map(\.name).sorted())
        }

        if let withoutImages = isoFiles.first(where: { $0.installImage == nil || $0.images.isEmpty }) {
            throw MediaPlanError.noInstallImage(withoutImages.name)
        }

        // The newest Windows supplies the boot files: its setup can deploy older
        // images, while an older setup cannot deploy newer ones.
        let ordered = isoFiles.sorted { left, right in
            if left.newestBuild != right.newestBuild { return left.newestBuild > right.newestBuild }
            if left.images.count != right.images.count { return left.images.count > right.images.count }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        guard let base = ordered.first(where: \.hasBootLoader) else {
            throw MediaPlanError.noBootLoader
        }

        // Two ISOs of the same release carry the same editions. Keeping both
        // would put identical entries in the setup menu.
        var seen: Set<String> = []
        var groups: [SourceGroup] = []

        for source in ordered {
            var planned: [PlannedImage] = []

            for image in source.images where seen.insert(image.mergedName).inserted {
                planned.append(PlannedImage(
                    index: image.index,
                    name: image.mergedName,
                    totalBytes: image.totalBytes
                ))
            }

            if !planned.isEmpty {
                groups.append(SourceGroup(source: source, images: planned))
            }
        }

        guard !groups.isEmpty else {
            throw MediaPlanError.noImages
        }

        // The base is mounted for its boot files even when an earlier ISO
        // already supplied every edition it holds.
        var sources = groups.map(\.source)
        if !sources.contains(base) {
            sources.insert(base, at: 0)
        }

        return InstallMediaPlan(
            mode: .merged(base: base, groups: groups, compression: compression(for: ordered)),
            sources: sources
        )
    }

    // Recompressing is the expensive part of a merge, so the merged image takes
    // the format that already holds most of the bytes.
    private static func compression(for isoFiles: [ISOFile]) -> WimLibService.Compression {
        let solidBytes: Int64 = isoFiles.reduce(0) { total, iso in
            guard let image = iso.installImage, !image.compression.isSplittable else { return total }
            return total + image.sizeBytes
        }

        let allBytes: Int64 = isoFiles.reduce(0) { $0 + ($1.installImage?.sizeBytes ?? 0) }

        return solidBytes * 2 > allBytes ? .solid : .lzx
    }
}

enum MediaPlanError: LocalizedError, Equatable {
    case noSources
    case noImages
    case noBootLoader
    case noInstallImage(String)
    case mixedArchitectures([String])

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "No ISO selected"
        case .noImages:
            return "No Windows image to install was found in the selected ISOs."
        case .noBootLoader:
            return "None of the selected ISOs can boot. Add one that contains a UEFI boot loader."
        case .noInstallImage(let name):
            return "\(name) has no Windows image to install. Remove it, or use it on its own."
        case .mixedArchitectures(let names):
            return "\(names.joined(separator: " and ")) ISOs cannot share a drive. Keep one architecture."
        }
    }
}
