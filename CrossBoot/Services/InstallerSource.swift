import Foundation

// The two installer sources that do not come from Apple's catalog: one the user
// already has on disk, and the list `softwareupdate` offers this Mac.
enum InstallerSource {

    private static let softwareupdate = "/usr/sbin/softwareupdate"
    private static let xar = "/usr/bin/xar"

    // MARK: - Local installer application

    static func installer(atApplication url: URL) async throws -> MacOSInstaller {
        let contents = url.appendingPathComponent("Contents")

        guard FileManager.default.fileExists(
            atPath: contents.appendingPathComponent("Resources/createinstallmedia").path
        ) else {
            throw MacOSMediaPlanError.installerUnreadable(url.lastPathComponent)
        }

        guard let release = await applicationRelease(in: contents) else {
            throw MacOSMediaPlanError.installerUnreadable(url.lastPathComponent)
        }

        return MacOSInstaller(
            name: applicationName(in: contents) ?? url.deletingPathExtension().lastPathComponent,
            version: release.version,
            build: release.build,
            sizeBytes: size(ofDirectory: url),
            // A bundle on disk carries no volume-check; it is already expanded,
            // so there is nothing left for this Mac to be too old to expand.
            minimumHostVersion: nil,
            origin: .application(url)
        )
    }

    // Apple has moved where an installer records its release: Big Sur and later
    // keep it inside SharedSupport.dmg, before that beside the image, older ones
    // again in InstallInfo.
    //
    // The bundle's own Info.plist is the last resort and a poor one - it
    // describes the installer application rather than the macOS it installs, so
    // a 15.7.9 (24G830) installer calls itself 15.7 (24G818) there - but a
    // wrong answer beats refusing an installer that would have worked.
    private static func applicationRelease(in contents: URL) async -> (version: MacOSVersion, build: String)? {
        let shared = contents.appendingPathComponent("SharedSupport")

        if let release = await sharedSupportRelease(at: shared.appendingPathComponent("SharedSupport.dmg")) {
            return release
        }

        if let asset = dictionary(at: shared.appendingPathComponent("com_apple_MobileAsset_MacSoftwareUpdate.xml")),
           let assets = asset["Assets"] as? [[String: Any]],
           let first = assets.first,
           let version = (first["OSVersion"] as? String).flatMap(MacOSVersion.init),
           let build = first["Build"] as? String {
            return (version, build)
        }

        if let info = dictionary(at: shared.appendingPathComponent("InstallInfo.plist")),
           let image = info["System Image Info"] as? [String: Any],
           let version = (image["version"] as? String).flatMap(MacOSVersion.init),
           let build = image["build"] as? String {
            return (version, build)
        }

        if let info = dictionary(at: contents.appendingPathComponent("Info.plist")),
           let version = (info["DTPlatformVersion"] as? String).flatMap(MacOSVersion.init) {
            return (version, info["DTSDKBuild"] as? String ?? "")
        }

        return nil
    }

    // Inside the image, the release is one field of one of the asset manifests
    // the installer would hand to the update machinery, or - on older installers
    // - the InstallInfo beside them.
    private static func sharedSupportRelease(at image: URL) async -> (version: MacOSVersion, build: String)? {
        guard FileManager.default.fileExists(atPath: image.path) else { return nil }

        return await DiskImage.read(image) { mount in
            let assets = mount.appendingPathComponent("com_apple_MobileAsset_MacSoftwareUpdate")
            let manifests = (try? FileManager.default.contentsOfDirectory(
                at: assets,
                includingPropertiesForKeys: nil
            )) ?? []

            for manifest in manifests where manifest.pathExtension == "json" {
                guard let data = try? Data(contentsOf: manifest),
                      let asset = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = (asset["OSVersion"] as? String).flatMap(MacOSVersion.init),
                      let build = asset["Build"] as? String else {
                    continue
                }

                return (version, build)
            }

            if let info = dictionary(at: mount.appendingPathComponent("InstallInfo.plist")),
               let image = info["System Image Info"] as? [String: Any],
               let version = (image["version"] as? String).flatMap(MacOSVersion.init),
               let build = image["build"] as? String {
                return (version, build)
            }

            return nil
        }
    }

    private static func applicationName(in contents: URL) -> String? {
        guard let info = dictionary(at: contents.appendingPathComponent("Info.plist")),
              let displayed = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String else {
            return nil
        }

        // "Install macOS Tahoe" names the application; the release is "macOS Tahoe".
        return displayed.hasPrefix("Install ") ? String(displayed.dropFirst("Install ".count)) : displayed
    }

    // Installers already expanded into /Applications, left there by an earlier
    // run or by Apple's own download. One of these costs nothing to use, so the
    // list has to know about them rather than offering the same release again as
    // a download.
    //
    // Reading each bundle walks it for its size, so this belongs off the main
    // thread with the other two sources.
    static func installedApplications(in directory: URL = URL(fileURLWithPath: "/Applications")) async -> [MacOSInstaller] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        // Apple names every one of them this way, and the alternative is reading
        // the Info.plist of every application on the Mac.
        let bundles = contents.filter {
            $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Install macOS ")
        }

        var installers: [MacOSInstaller] = []

        for bundle in bundles {
            guard let installer = try? await installer(atApplication: bundle) else { continue }
            installers.append(installer)
        }

        return installers.sorted { $0.version > $1.version }
    }

    // MARK: - Local InstallAssistant package

    // A flat package carries the same distribution file the catalog serves, so
    // one member is extracted rather than expanding an 18 GB payload.
    static func installer(atPackage url: URL) async throws -> MacOSInstaller {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await ShellHelper.run(xar, ["-xf", url.path, "Distribution", "-C", directory.path])

        guard let text = try? String(contentsOf: directory.appendingPathComponent("Distribution"), encoding: .utf8),
              let distribution = DistributionParser.parse(text) else {
            throw MacOSMediaPlanError.installerUnreadable(url.lastPathComponent)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        return MacOSInstaller(
            name: distribution.title,
            version: distribution.version,
            build: distribution.build,
            sizeBytes: attributes?[.size] as? Int64 ?? 0,
            minimumHostVersion: distribution.minimumHostVersion,
            origin: .package(url)
        )
    }

    // MARK: - softwareupdate

    static func softwareUpdateInstallers() async throws -> [MacOSInstaller] {
        let output = try await ShellHelper.run(softwareupdate, ["--list-full-installers"])
        return parseFullInstallers(output)
    }

    // Lines look like:
    // * Title: macOS Tahoe, Version: 26.6.2, Size: 17953734KiB, Build: 25G83, Deferred: NO
    static func parseFullInstallers(_ output: String) -> [MacOSInstaller] {
        var installers: [MacOSInstaller] = []
        var seen: Set<String> = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* ") else { continue }

            var fields: [String: String] = [:]
            for field in trimmed.dropFirst(2).components(separatedBy: ", ") {
                let parts = field.components(separatedBy: ": ")
                guard parts.count == 2 else { continue }
                fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }

            guard let title = fields["Title"],
                  let version = fields["Version"].flatMap(MacOSVersion.init),
                  let build = fields["Build"],
                  seen.insert("\(title) \(version) \(build)").inserted else {
                continue
            }

            installers.append(MacOSInstaller(
                name: title,
                version: version,
                build: build,
                sizeBytes: kibibytes(fields["Size"]),
                // softwareupdate only ever lists what this Mac can already have.
                minimumHostVersion: nil,
                origin: .softwareUpdate
            ))
        }

        return installers.sorted { $0.version > $1.version }
    }

    private static func kibibytes(_ text: String?) -> Int64 {
        guard let value = text?.replacingOccurrences(of: "KiB", with: ""), let size = Int64(value) else { return 0 }
        return size * 1024
    }

    // MARK: - Helpers

    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func size(ofDirectory url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }

        return total
    }
}
