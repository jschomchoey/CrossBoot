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
        case merged(base: ISOFile, groups: [SourceGroup], compression: WimCompression)
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

    // What has to happen to a lone ISO's install image before FAT32 can hold it.
    enum InstallImageWork: Equatable {
        // It fits, so the ISO is copied exactly as it is.
        case copyWhole
        // Too big for FAT32, but splittable in the format it already has.
        case split
        // Too big for FAT32 and solid, which wimlib cannot split. It has to be
        // rewritten in a splittable format first, and only then split.
        case rebuild(WimCompression)
    }

    static func work(for iso: ISOFile) -> InstallImageWork {
        guard let image = iso.installImage, image.sizeBytes > WimLibService.fat32FileLimit else {
            return .copyWhole
        }

        return image.compression.isSplittable ? .split : .rebuild(rebuildCompression(for: [image]))
    }

    // An upper bound on what the drive has to hold: the base ISO without its own
    // install image, plus every install image being merged in, at the size it
    // will have once rewritten. Deduplication between images can only make the
    // result smaller.
    var estimatedDriveBytes: Int64 {
        switch mode {
        case .single(let iso):
            guard case .rebuild = Self.work(for: iso), let image = iso.installImage else {
                return iso.sizeBytes
            }
            // The rewritten image replaces the one already counted in the ISO.
            return iso.sizeBytes - image.sizeBytes + Self.rebuiltBytes(of: image)
        case .merged(_, let groups, _):
            let baseTree = base.sizeBytes - (base.installImage?.sizeBytes ?? 0)
            return baseTree + groups.reduce(0) { $0 + Self.rebuiltBytes(of: $1.source.installImage) }
        }
    }

    // Peak scratch space: the rewritten image, plus the split parts written
    // beside it before it is deleted.
    var estimatedTemporaryBytes: Int64 {
        switch mode {
        case .single(let iso):
            guard let image = iso.installImage else { return 0 }

            switch Self.work(for: iso) {
            case .copyWhole: return 0
            case .split: return image.sizeBytes
            case .rebuild: return Self.rebuiltBytes(of: image) * 2
            }
        case .merged(_, let groups, _):
            let merged = groups.reduce(0) { $0 + Self.rebuiltBytes(of: $1.source.installImage) }
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
            mode: .merged(
                base: base,
                groups: groups,
                compression: rebuildCompression(for: groups.compactMap { $0.source.installImage })
            ),
            sources: sources
        )
    }

    // The format a rewritten install image takes.
    //
    // Solid (LZMS) is never a candidate. Merged media is all but always over the
    // FAT32 limit and therefore has to be split, and wimlib cannot split a WIM
    // holding solid resources - a solid destination fails the run at the split,
    // with the drive already erased.
    //
    // That leaves LZX and XPRESS. wimlib copies data across untouched when the
    // destination format matches the source, which on real install media is
    // about 20 seconds against 2 minutes per edition - so XPRESS wins when most
    // of the bytes already are XPRESS. Everything else takes LZX: it is what
    // Windows media ships as install.wim, and it is the smaller of the two on a
    // drive that has to hold it.
    static func rebuildCompression(for images: [InstallImage]) -> WimCompression {
        let allBytes = images.reduce(0) { $0 + $1.sizeBytes }
        let xpressBytes = images
            .filter { $0.compression == .xpress }
            .reduce(0) { $0 + $1.sizeBytes }

        return xpressBytes * 2 > allBytes ? .xpress : .lzx
    }

    // Rewriting a solid image in a splittable format gives back about half of
    // what solid compression saved. Every space check runs before the drive is
    // erased, so it has to expect the bigger file.
    private static let solidExpansion = 1.5

    private static func rebuiltBytes(of image: InstallImage?) -> Int64 {
        guard let image else { return 0 }

        return image.compression.isSplittable
            ? image.sizeBytes
            : Int64(Double(image.sizeBytes) * solidExpansion)
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
