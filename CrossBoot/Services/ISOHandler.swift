import Foundation

// Handles ISO mounting, file copying, and WIM operations
actor ISOHandler {
    static let shared = ISOHandler()
    
    private var currentMountPoint: String?
    private var tempDirectory: URL?
    
    private init() {}
    
    // Mount an ISO file and return the mount point
    func mountISO(_ isoURL: URL) async throws -> String {
        let output = try await ShellHelper.run("hdiutil mount -nobrowse \"\(isoURL.path)\"")
        
        guard let match = output.range(of: "/Volumes/.+", options: .regularExpression),
              !output[match].isEmpty else {
            throw ISOError.mountFailed
        }
        
        let mountPoint = String(output[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        currentMountPoint = mountPoint
        return mountPoint
    }
    
    // Unmount the ISO
    func unmountISO() async {
        guard let mountPoint = currentMountPoint else { return }
        _ = try? await ShellHelper.run("hdiutil detach \"\(mountPoint)\" -force")
        currentMountPoint = nil
    }
    
    // Check > 4GB for FAT32
    func checkWIMSize(_ mountPoint: String) async -> (needsSplit: Bool, wimPath: String?) {
        let wimPath = "\(mountPoint)/sources/install.wim"
        
        guard FileManager.default.fileExists(atPath: wimPath) else {
            return (false, nil)
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: wimPath)
            let size = attributes[.size] as? Int64 ?? 0
            let fourGB: Int64 = 4 * 1024 * 1024 * 1024
            
            return (size > fourGB, wimPath)
        } catch {
            return (false, nil)
        }
    }
    
    // Get all files in the mounted ISO
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
    
    // Copy files to USB
    func copyFilesToUSB(
        from mountPoint: String,
        to usbPath: String,
        splitTempDir: URL?,
        skipInstallWim: Bool,
        onProgress: @escaping (Double, String) -> Void
    ) async throws {
        var filesToCopy = try getAllFiles(mountPoint)
        
        if skipInstallWim {
            filesToCopy = filesToCopy.filter { !$0.path.lowercased().hasSuffix("install.wim") }
        }
        
        if let tempDir = splitTempDir {
            let swmFiles = try getAllFiles(tempDir.path)
            for swm in swmFiles {
                filesToCopy.append((path: swm.path, size: swm.size))
            }
        }
        
        let totalBytes = filesToCopy.reduce(0) { $0 + $1.size }
        var copiedBytes: Int64 = 0
        
        let fileManager = FileManager.default
        let bufferSize = 32 * 1024 * 1024 // 32MB buffer
        
        for file in filesToCopy {
            try Task.checkCancellation()
            
            let relativePath: String
            if let tempDir = splitTempDir, file.path.hasPrefix(tempDir.path) {
                let fileName = (file.path as NSString).lastPathComponent
                relativePath = "sources/\(fileName)"
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
                if bytesRead > 0 {
                    outputStream.write(buffer, maxLength: bytesRead)
                    copiedBytes += Int64(bytesRead)
                    
                    let progress = min(100, Double(copiedBytes) / Double(totalBytes) * 100)
                    await MainActor.run {
                        onProgress(progress, fileName)
                    }
                } else if bytesRead < 0 {
                    throw ISOError.copyFailed("Read error: \(fileName)")
                }
            }
        }
    }
    
    /// Create autounattend.xml for Windows 11 bypass
    func createAutounattend(
        at usbPath: String,
        bypassRequirements: Bool,
        bypassOnlineAccount: Bool
    ) throws {
        var content = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
        """
        
        if bypassRequirements {
            content += """
            
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
                <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
    
    // Cleanup temp directory
    func cleanup() async {
        await unmountISO()
        
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
            tempDirectory = nil
        }
    }
    
    func setTempDirectory(_ url: URL) {
        tempDirectory = url
    }
}

enum ISOError: LocalizedError {
    case mountFailed
    case enumerationFailed
    case copyFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .mountFailed: return "Failed to mount ISO"
        case .enumerationFailed: return "Failed to enumerate files"
        case .copyFailed(let msg): return msg
        }
    }
}
