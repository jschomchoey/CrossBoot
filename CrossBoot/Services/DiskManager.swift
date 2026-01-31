import Foundation

/// Manages USB drive detection and formatting
actor DiskManager {
    static let shared = DiskManager()
    
    private init() {}
    
    /// List all removable USB drives
    func listRemovableDrives() async -> [Drive] {
        do {
            let output = try await ShellHelper.run("diskutil list -plist external physical")
            return parseDiskutilOutput(output)
        } catch {
            print("Failed to list drives: \(error)")
            return []
        }
    }
    
    /// Parse diskutil plist output to extract drives
    private func parseDiskutilOutput(_ plistString: String) -> [Drive] {
        guard let data = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }
        
        var drives: [Drive] = []
        
        for disk in allDisks {
            guard let deviceIdentifier = disk["DeviceIdentifier"] as? String else { continue }
            
            // Get disk info for this device
            if let info = getDiskInfo(deviceIdentifier) {
                drives.append(info)
            }
        }
        
        return drives
    }
    
    /// Get detailed info for a specific disk
    private func getDiskInfo(_ identifier: String) -> Drive? {
        let device = "/dev/\(identifier)"
        
        do {
            let output = try ShellHelper.runSync("diskutil info -plist \(device)")
            guard let data = output.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }
            
            // Check if it's removable and not internal
            let removable = plist["Removable"] as? Bool ?? false
            let ejectable = plist["Ejectable"] as? Bool ?? false
            let isInternal = plist["Internal"] as? Bool ?? true
            
            guard (removable || ejectable) && !isInternal else { return nil }
            
            let name = plist["MediaName"] as? String ?? plist["VolumeName"] as? String ?? "USB Drive"
            let size = plist["TotalSize"] as? Int64 ?? 0
            
            return Drive(
                id: identifier,
                device: device,
                name: name.isEmpty ? "USB Drive" : name,
                size: size
            )
        } catch {
            return nil
        }
    }
    
    /// Format a drive to FAT32 with MBR scheme
    func formatDrive(_ device: String) async throws {
        // Safety check - never format disk0 (system disk)
        guard !device.contains("disk0") else {
            throw DiskError.systemDiskProtection
        }
        
        let command = "diskutil eraseDisk MS-DOS \"WINDOWS\" MBR \"\(device)\""
        try await ShellHelper.run(command, asAdmin: false)
    }
    
    /// Get mount point for a device
    func getMountPoint(_ device: String) async -> String? {
        // Try multiple times as disk may take time to mount after formatting
        for attempt in 1...5 {
            // Wait longer on each attempt
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            
            // Try to get mount point from main device
            if let mount = await getMountPointFromDevice(device) {
                return mount
            }
            
            // Also try the first partition (e.g., disk2s1)
            let diskId = device.replacingOccurrences(of: "/dev/", with: "")
            let partitionDevice = "/dev/\(diskId)s1"
            if let mount = await getMountPointFromDevice(partitionDevice) {
                return mount
            }
            
            print("Mount point not found, attempt \(attempt)/5...")
        }
        
        return nil
    }
    
    /// Helper to get mount point from a specific device
    private func getMountPointFromDevice(_ device: String) async -> String? {
        do {
            let output = try await ShellHelper.run("diskutil info -plist \(device)")
            
            guard let data = output.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let mountPoint = plist["MountPoint"] as? String,
                  !mountPoint.isEmpty else {
                return nil
            }
            
            return mountPoint
        } catch {
            return nil
        }
    }
}

// Synchronous helper for disk info parsing
extension ShellHelper {
    static func runSync(_ command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum DiskError: LocalizedError {
    case systemDiskProtection
    case formatFailed(String)
    case mountPointNotFound
    
    var errorDescription: String? {
        switch self {
        case .systemDiskProtection: return "Cannot format system disk"
        case .formatFailed(let msg): return "Format failed: \(msg)"
        case .mountPointNotFound: return "Could not find USB mount point"
        }
    }
}
