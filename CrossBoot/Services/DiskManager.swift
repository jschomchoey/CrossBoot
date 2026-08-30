import Foundation
import DiskArbitration

// Manages USB drive detection and formatting
actor DiskManager {
    static let shared = DiskManager()

    private static let diskutil = "/usr/sbin/diskutil"

    private var diskSession: DASession?
    private var onDiskChange: (() -> Void)?

    private init() {}

    // Start monitoring disk changes
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

            guard let self = self else { return }
            DiskChangeHandler.shared.setHandler(onChange, owner: self)
        }
    }

    private func setSession(_ session: DASession) {
        diskSession = session
    }

    // Stop monitoring disk changes
    func stopMonitoring() {
        diskSession = nil
        onDiskChange = nil
    }

    // List all removable USB drives
    func listRemovableDrives() async -> [Drive] {
        do {
            let output = try await ShellHelper.run(Self.diskutil, ["list", "-plist", "external", "physical"])
            let identifiers = Self.parseDiskIdentifiers(output)

            // Each disk needs its own `diskutil info`; run them concurrently
            // rather than blocking on one process at a time.
            return await withTaskGroup(of: Drive?.self) { group in
                for identifier in identifiers {
                    group.addTask { await Self.removableDrive(identifier) }
                }

                var drives: [Drive] = []
                for await drive in group {
                    if let drive { drives.append(drive) }
                }
                // Task groups finish out of order; keep the picker order stable.
                return drives.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            }
        } catch {
            print("Failed to list drives: \(error.localizedDescription)")
            return []
        }
    }

    // Extract the disk identifiers from `diskutil list -plist`
    private static func parseDiskIdentifiers(_ plistString: String) -> [String] {
        guard let data = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        return allDisks.compactMap { $0["DeviceIdentifier"] as? String }
    }

    // Describe a disk, or nil when it is not a removable external drive
    private static func removableDrive(_ identifier: String) async -> Drive? {
        let device = "/dev/\(identifier)"
        guard let info = try? await diskInfo(device) else { return nil }

        let removable = info["Removable"] as? Bool ?? false
        let ejectable = info["Ejectable"] as? Bool ?? false
        let isInternal = info["Internal"] as? Bool ?? true

        guard (removable || ejectable) && !isInternal else { return nil }

        let name = (info["MediaName"] as? String ?? info["VolumeName"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Drive(
            id: identifier,
            device: device,
            name: name.isEmpty ? "USB Drive" : name,
            size: info["TotalSize"] as? Int64 ?? 0
        )
    }

    // Decoded `diskutil info -plist` for a device
    static func diskInfo(_ device: String) async throws -> [String: Any] {
        let output = try await ShellHelper.run(diskutil, ["info", "-plist", device])

        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw DiskError.infoUnavailable(device)
        }

        return plist
    }

    // Format drive to FAT32 with MBR
    func formatDrive(_ device: String) async throws {
        guard !device.contains("disk0") else {
            throw DiskError.systemDiskProtection
        }

        try await ShellHelper.run(Self.diskutil, ["eraseDisk", "MS-DOS", "WINDOWS", "MBR", device])
    }

    // Get mount point
    func getMountPoint(_ device: String) async -> String? {
        for attempt in 1...5 {
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)

            if let mount = await Self.mountPoint(ofDevice: device) {
                return mount
            }

            // Also try the first partition
            let diskId = device.replacingOccurrences(of: "/dev/", with: "")
            if let mount = await Self.mountPoint(ofDevice: "/dev/\(diskId)s1") {
                return mount
            }

            print("Mount point not found, attempt \(attempt)/5...")
        }

        return nil
    }

    // Helper to get mount point from a specific device
    private static func mountPoint(ofDevice device: String) async -> String? {
        guard let info = try? await diskInfo(device),
              let mountPoint = info["MountPoint"] as? String,
              !mountPoint.isEmpty else {
            return nil
        }

        return mountPoint
    }
}

// Helper class for disk change callbacks
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
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.handlerOwner != nil else { return }
            self?.onChange?()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func clearHandler() {
        onChange = nil
        handlerOwner = nil
    }
}

enum DiskError: LocalizedError {
    case systemDiskProtection
    case infoUnavailable(String)
    case mountPointNotFound

    var errorDescription: String? {
        switch self {
        case .systemDiskProtection: return "Cannot format system disk"
        case .infoUnavailable(let device): return "Could not read disk information for \(device)"
        case .mountPointNotFound: return "Could not find USB mount point"
        }
    }
}
