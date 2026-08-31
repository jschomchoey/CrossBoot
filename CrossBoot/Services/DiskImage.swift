import Foundation

// Reads something out of a disk image without leaving it behind.
//
// A macOS installer keeps what it is inside SharedSupport.dmg, so answering
// "which release is this" means attaching 15 GB for a moment.
enum DiskImage {
    private static let hdiutil = "/usr/bin/hdiutil"

    // Hands the mount point to `read`. An image the system already has attached
    // - createinstallmedia leaves the installer's own SharedSupport mounted - is
    // read where it stands, and only an image this call attached is detached.
    static func read<T>(_ image: URL, _ body: (URL) -> T?) async -> T? {
        if let mounted = await mountPoint(of: image) {
            return body(mounted)
        }

        guard let attached = await attach(image) else { return nil }

        let value = body(attached)
        await detach(attached)

        return value
    }

    private static func attach(_ image: URL) async -> URL? {
        // Mounted where this app keeps its own scratch rather than in /Volumes:
        // it is nobody's disk but ours, it cannot collide with a volume of the
        // same name, and it leaves the Finder's sidebar alone.
        let mountpoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-image-\(UUID().uuidString)")

        guard (try? FileManager.default.createDirectory(
            at: mountpoint,
            withIntermediateDirectories: true
        )) != nil else {
            return nil
        }

        // Nothing is written and nobody is asked to look at it: read-only so the
        // image cannot be changed, nobrowse so it does not appear in the Finder,
        // and unverified because checksumming 15 GB to read one file is absurd.
        let attached = try? await ShellHelper.run(
            hdiutil,
            [
                "attach", image.path,
                "-readonly", "-nobrowse", "-noverify", "-plist",
                "-mountpoint", mountpoint.path
            ]
        )

        guard attached != nil else {
            try? FileManager.default.removeItem(at: mountpoint)
            return nil
        }

        return mountpoint
    }

    private static func detach(_ mount: URL) async {
        _ = try? await ShellHelper.run(hdiutil, ["detach", mount.path, "-quiet"])

        try? FileManager.default.removeItem(at: mount)
    }

    private static func mountPoint(of image: URL) async -> URL? {
        guard let output = try? await ShellHelper.run(hdiutil, ["info", "-plist"]),
              let plist = self.plist(output),
              let images = plist["images"] as? [[String: Any]] else {
            return nil
        }

        let attached = images.first { $0["image-path"] as? String == image.path }

        return attached.flatMap { mountPoint(inEntities: $0) }
    }

    // hdiutil reports one entity per partition, and only the one carrying a
    // filesystem was mounted anywhere.
    private static func mountPoint(inEntities dictionary: [String: Any]) -> URL? {
        guard let entities = dictionary["system-entities"] as? [[String: Any]] else { return nil }

        let mounted = entities.compactMap { $0["mount-point"] as? String }

        return mounted.first.map { URL(fileURLWithPath: $0) }
    }

    private static func plist(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8) else { return nil }

        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
