import Foundation

// Handles ISO mounting, inspection and file copying. Everything a run mounts or
// writes to scratch space is tracked here so `cleanup()` can release all of it.
actor ISOHandler {
    static let shared = ISOHandler()

    private static let hdiutil = "/usr/bin/hdiutil"

    private var mountPoints: Set<String> = []
    private var temporaryDirectories: [URL] = []

    private init() {}

    // MARK: - Mounting

    func mountISO(_ isoURL: URL) async throws -> String {
        // -plist keeps this off free-form output: an image can expose several
        // entities and only some of them carry a mount point.
        let output = try await ShellHelper.run(Self.hdiutil, ["mount", "-plist", "-nobrowse", isoURL.path])

        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first(where: { !$0.isEmpty }) else {
            throw ISOError.mountFailed
        }

        mountPoints.insert(mountPoint)
        return mountPoint
    }

    func unmountISO(_ mountPoint: String) async {
        guard mountPoints.contains(mountPoint) else { return }
        _ = try? await ShellHelper.run(Self.hdiutil, ["detach", mountPoint, "-force"])
        mountPoints.remove(mountPoint)
    }

    // MARK: - Inspection

    // Mount an ISO just long enough to learn what is inside it. Doing this when
    // the file is picked means an unusable combination is refused before the
    // drive is erased rather than halfway through a run.
    func analyze(_ isoURL: URL) async throws -> ISOFile {
        let mountPoint = try await mountISO(isoURL)

        do {
            var installImage: InstallImage?
            var images: [WindowsImage] = []

            // The file name says nothing about how the image is compressed - an
            // install.esd renamed to install.wim is common - and compression is
            // what decides whether FAT32 can be served by splitting it.
            if let found = Self.installImage(in: mountPoint) {
                let path = (mountPoint as NSString).appendingPathComponent(found.relativePath)
                let inspection = try await WimLibService.shared.inspect(at: path)

                installImage = InstallImage(
                    relativePath: found.relativePath,
                    sizeBytes: found.sizeBytes,
                    compression: inspection.compression
                )
                images = inspection.images
            }

            let iso = try ISOFile(
                url: isoURL,
                installImage: installImage,
                images: images,
                hasBootLoader: Self.hasBootLoader(in: mountPoint)
            )

            await unmountISO(mountPoint)
            return iso
        } catch {
            await unmountISO(mountPoint)
            throw error
        }
    }

    // Locate sources/install.wim or sources/install.esd. ISO filesystems are
    // case-sensitive on macOS while Windows media is inconsistent about case, so
    // every component is matched without regard to it. Compression is left to
    // the caller: only wimlib can read it out of the file itself.
    static func installImage(in mountPoint: String) -> (relativePath: String, sizeBytes: Int64)? {
        guard let sources = entry(named: "sources", in: mountPoint) else { return nil }

        for fileName in ["install.wim", "install.esd"] {
            guard let path = entry(named: fileName, in: sources),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                continue
            }

            return (
                relativePath: String(path.dropFirst(mountPoint.count + 1)),
                sizeBytes: attributes[.size] as? Int64 ?? 0
            )
        }

        return nil
    }

    // The signed loader firmware runs first. Without it the media cannot boot at
    // all, let alone with Secure Boot on.
    static func hasBootLoader(in mountPoint: String) -> Bool {
        guard let efi = entry(named: "EFI", in: mountPoint),
              let boot = entry(named: "boot", in: efi),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: boot) else {
            return false
        }

        return contents.contains { $0.lowercased().hasSuffix(".efi") }
    }

    private static func entry(named name: String, in directory: String) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory),
              let match = contents.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }

        return (directory as NSString).appendingPathComponent(match)
    }

    // MARK: - Copying

    func getAllFiles(_ directory: String) throws -> [(path: String, size: Int64)] {
        var results: [(path: String, size: Int64)] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(atPath: directory) else {
            throw ISOError.enumerationFailed
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (directory as NSString).appendingPathComponent(relativePath)

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue {
                let attributes = try? fileManager.attributesOfItem(atPath: fullPath)
                let size = attributes?[.size] as? Int64 ?? 0
                results.append((path: fullPath, size: size))
            }
        }

        return results
    }

    // Copy the base ISO onto the drive, minus the paths the run replaces, plus
    // whatever `installSources` holds - the merged or split install image, which
    // always lands in sources/.
    func copyFilesToUSB(
        from mountPoint: String,
        to usbPath: String,
        excluding excludedRelativePaths: Set<String>,
        installSources: URL?,
        onProgress: @escaping @Sendable @MainActor (Double, String) -> Void
    ) async throws {
        var filesToCopy = try getAllFiles(mountPoint).filter { file in
            let relativePath = String(file.path.dropFirst(mountPoint.count + 1)).lowercased()
            return !excludedRelativePaths.contains(relativePath)
        }

        if let installSources {
            filesToCopy.append(contentsOf: try getAllFiles(installSources.path))
        }

        let totalBytes = filesToCopy.reduce(0) { $0 + $1.size }
        guard totalBytes > 0 else {
            throw ISOError.emptySource
        }

        var copiedBytes: Int64 = 0

        let fileManager = FileManager.default
        let bufferSize = 32 * 1024 * 1024 // 32MB buffer

        for file in filesToCopy {
            try Task.checkCancellation()

            let relativePath: String
            if let installSources, file.path.hasPrefix(installSources.path) {
                relativePath = "sources/\((file.path as NSString).lastPathComponent)"
            } else {
                relativePath = String(file.path.dropFirst(mountPoint.count + 1))
            }

            let destPath = (usbPath as NSString).appendingPathComponent(relativePath)
            let destDir = (destPath as NSString).deletingLastPathComponent

            try fileManager.createDirectory(atPath: destDir, withIntermediateDirectories: true)

            let fileName = (file.path as NSString).lastPathComponent

            guard let inputStream = InputStream(fileAtPath: file.path) else {
                throw ISOError.copyFailed("Cannot open \(fileName)")
            }

            try? fileManager.removeItem(atPath: destPath)

            guard let outputStream = OutputStream(toFileAtPath: destPath, append: false) else {
                throw ISOError.copyFailed("Cannot create \(fileName)")
            }

            inputStream.open()
            outputStream.open()
            defer {
                inputStream.close()
                outputStream.close()
            }

            var buffer = [UInt8](repeating: 0, count: bufferSize)

            while inputStream.hasBytesAvailable {
                try Task.checkCancellation()

                let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
                guard bytesRead != 0 else { break }
                guard bytesRead > 0 else {
                    throw ISOError.readFailed(
                        file: fileName,
                        reason: inputStream.streamError?.localizedDescription
                    )
                }

                try write(buffer, count: bytesRead, to: outputStream, fileName: fileName)
                copiedBytes += Int64(bytesRead)

                let progress = min(100, Double(copiedBytes) / Double(totalBytes) * 100)
                await onProgress(progress, fileName)
            }
        }
    }

    // OutputStream accepts fewer bytes than offered once the destination fills
    // up. Ignoring the count silently truncates files and still reports success,
    // so keep writing until the whole chunk lands.
    private func write(
        _ buffer: [UInt8],
        count: Int,
        to stream: OutputStream,
        fileName: String
    ) throws {
        var written = 0

        while written < count {
            let result = buffer.withUnsafeBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return stream.write(base + written, maxLength: count - written)
            }

            guard result > 0 else {
                throw ISOError.writeFailed(
                    file: fileName,
                    reason: stream.streamError?.localizedDescription
                )
            }

            written += result
        }
    }

    /// Create autounattend.xml for Windows 11 bypass
    func createAutounattend(
        at usbPath: String,
        architecture: WindowsArchitecture,
        bypassRequirements: Bool,
        bypassOnlineAccount: Bool
    ) throws {
        let processorArchitecture = architecture.unattendName

        var content = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
        """

        if bypassRequirements {
            content += """
            
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup" processorArchitecture="\(processorArchitecture)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                    <UserData>
                        <ProductKey>
                            <Key></Key>
                        </ProductKey>
                    </UserData>
                    <RunSynchronous>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>2</Order>
                            <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>3</Order>
                            <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>4</Order>
                            <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>5</Order>
                            <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                    </RunSynchronous>
                </component>
            </settings>
            """
        }

        if bypassOnlineAccount {
            content += """
            
            <settings pass="specialize">
                <component name="Microsoft-Windows-Deployment" processorArchitecture="\(processorArchitecture)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                    <RunSynchronous>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Path>reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                    </RunSynchronous>
                </component>
            </settings>
            """
        }

        content += """
        
        </unattend>
        """

        let autounattendPath = (usbPath as NSString).appendingPathComponent("autounattend.xml")
        try content.write(toFile: autounattendPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Scratch space

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossboot-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // Release everything the run acquired, whether it finished or was stopped.
    func cleanup() async {
        for mountPoint in mountPoints {
            _ = try? await ShellHelper.run(Self.hdiutil, ["detach", mountPoint, "-force"])
        }
        mountPoints.removeAll()

        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }
}

enum ISOError: LocalizedError {
    case mountFailed
    case enumerationFailed
    case emptySource
    case copyFailed(String)
    case readFailed(file: String, reason: String?)
    case writeFailed(file: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .mountFailed:
            return "Failed to mount ISO"
        case .enumerationFailed:
            return "Failed to enumerate files"
        case .emptySource:
            return "The ISO contains no files to copy"
        case .copyFailed(let message):
            return message
        case .readFailed(let file, let reason):
            return "Failed to read \(file): \(reason ?? "the ISO may be damaged")"
        case .writeFailed(let file, let reason):
            return "Failed to write \(file): \(reason ?? "the drive may be full or disconnected")"
        }
    }
}
