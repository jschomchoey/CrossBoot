import Foundation
import DiskArbitration

/// Manages USB drive detection and formatting
actor DiskManager {
    static let shared = DiskManager()
    
    private var diskSession: DASession?
    private var onDiskChange: (() -> Void)?
    
    private init() {}
    
    /// Start monitoring disk changes
    func startMonitoring(onChange: @escaping () -> Void) {
        onDiskChange = onChange
        
        Task.detached { [weak self] in
            guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
            await self?.setSession(session)
            
            DASessionSetDispatchQueue(session, DispatchQueue.main)
            
            // Register for disk appeared events
            DARegisterDiskAppearedCallback(session, nil, { disk, context in
                guard let context = context else { return }
                let manager = Unmanaged<DiskChangeHandler>.fromOpaque(context).takeUnretainedValue()
                manager.handleChange()
            }, Unmanaged.passUnretained(DiskChangeHandler.shared).toOpaque())
            
            // Register for disk disappeared events
            DARegisterDiskDisappearedCallback(session, nil, { disk, context in
                guard let context = context else { return }
                let manager = Unmanaged<DiskChangeHandler>.fromOpaque(context).takeUnretainedValue()
                manager.handleChange()
            }, Unmanaged.passUnretained(DiskChangeHandler.shared).toOpaque())
            
            // Set the change handler
            guard let self = self else { return }
            DiskChangeHandler.shared.setHandler(onChange, owner: self)
        }
    }
    
    private func setSession(_ session: DASession) {
        diskSession = session
    }
    
    /// Stop monitoring disk changes
    func stopMonitoring() {
        diskSession = nil
        onDiskChange = nil
    }
    
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

/// Helper class for disk change callbacks (must be a class for Unmanaged)
class DiskChangeHandler {
    static let shared = DiskChangeHandler()
    private weak var handlerOwner: AnyObject?
    private var onChange: (() -> Void)?
    private var debounceWorkItem: DispatchWorkItem?
    
    func setHandler(_ handler: @escaping () -> Void, owner: AnyObject) {
        handlerOwner = owner
        onChange = handler
    }
    
    func handleChange() {
        guard handlerOwner != nil else {
            onChange = nil
            return
        }
        
        // Debounce rapid changes
        debounceWorkItem?.cancel()
        debounceWorkItem = DispatchWorkItem { [weak self] in
            guard self?.handlerOwner != nil else { return }
            self?.onChange?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: debounceWorkItem!)
    }
    
    func clearHandler() {
        onChange = nil
        handlerOwner = nil
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
