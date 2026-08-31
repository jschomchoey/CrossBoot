import Foundation

// How one macOS installer becomes a bootable drive.
//
// Nothing about the installer is rewritten. Apple's createinstallmedia lays the
// drive out itself, so the media carries Apple's own boot files and its own
// signatures - the same reasoning that keeps the Windows side from rebuilding
// Microsoft's boot chain.
struct MacOSMediaPlan {
    let installer: MacOSInstaller

    // What the drive has to hold: the installer application, plus room for the
    // filesystem createinstallmedia writes around it. Apple quotes a flat 14 GB
    // volume, but installers now run from 12 GB (Ventura) to 18 GB (Tahoe), so
    // the figure is taken from the installer rather than fixed.
    var estimatedDriveBytes: Int64 {
        installer.sizeBytes + installer.sizeBytes / 10
    }

    // Peak free space needed on this Mac's own disk before the drive is touched.
    // A downloaded package and the application it expands into exist at the same
    // time; an installer the user already has costs nothing.
    var estimatedTemporaryBytes: Int64 {
        switch installer.origin {
        case .catalog: return installer.sizeBytes * 2
        case .package, .softwareUpdate: return installer.sizeBytes
        case .application: return 0
        }
    }

    // Whether this Mac's hardware is Apple Silicon, read from the hardware
    // rather than the build architecture so a translated process still answers
    // for the machine it is running on.
    //
    // Every row of the version list asks this on every redraw, and the answer
    // cannot change while the app is running.
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size

        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }()

    // Big Sur was the first macOS to run on Apple Silicon. An older installer
    // can be written to a drive here, but nothing that drive could boot exists.
    private static let firstAppleSiliconMajor = 11

    static func make(
        for installer: MacOSInstaller,
        host: MacOSVersion = .host,
        appleSilicon: Bool = MacOSMediaPlan.isAppleSilicon
    ) throws -> MacOSMediaPlan {
        if let minimum = installer.minimumHostVersion, host < minimum {
            throw MacOSMediaPlanError.hostTooOld(
                name: installer.title,
                required: minimum,
                host: host
            )
        }

        if appleSilicon, installer.version.major < firstAppleSiliconMajor {
            throw MacOSMediaPlanError.intelOnly(name: installer.title)
        }

        return MacOSMediaPlan(installer: installer)
    }

    // Whether the version list should mark an entry as unusable here, without
    // raising it as an error the user has not asked for yet.
    static func refusal(
        for installer: MacOSInstaller,
        host: MacOSVersion = .host,
        appleSilicon: Bool = MacOSMediaPlan.isAppleSilicon
    ) -> MacOSMediaPlanError? {
        do {
            _ = try make(for: installer, host: host, appleSilicon: appleSilicon)
            return nil
        } catch let error as MacOSMediaPlanError {
            return error
        } catch {
            return nil
        }
    }
}

enum MacOSMediaPlanError: LocalizedError, Equatable {
    case noInstaller
    case hostTooOld(name: String, required: MacOSVersion, host: MacOSVersion)
    case intelOnly(name: String)
    case installerUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .noInstaller:
            return "No macOS version selected"
        case .hostTooOld(let name, let required, let host):
            return "\(name) has to be built on macOS \(required) or later, and this Mac runs \(host)."
        case .intelOnly(let name):
            return "\(name) never ran on Apple Silicon, so a drive holding it could not boot this Mac."
        case .installerUnreadable(let name):
            return "\(name) is not a macOS installer. Choose an \"Install macOS\" app or an InstallAssistant package."
        }
    }

    // The short form the version list puts on a row it has marked.
    var shortReason: String {
        switch self {
        case .noInstaller: return "none"
        case .hostTooOld(_, let required, _): return "needs macOS \(required)"
        case .intelOnly: return "Intel only"
        case .installerUnreadable: return "unreadable"
        }
    }
}
