import Foundation

// One macOS version that can be written to a drive, and where it comes from.
//
// The three origins differ only in how the installer application is obtained.
// Once it exists, every one of them is written by Apple's own createinstallmedia
// out of that application, so the boot chain is Apple's and stays signed.
struct MacOSInstaller: Identifiable, Hashable {
    enum Origin: Hashable {
        // Apple's software update catalog, which is not filtered by hardware -
        // this is the only origin that can offer a version newer than the one
        // Apple would hand this Mac.
        case catalog(productID: String, packageURL: URL)
        // softwareupdate --fetch-full-installer, limited to what the catalog
        // serves this particular Mac.
        case softwareUpdate
        // An "Install macOS X.app" the user already has.
        case application(URL)
        // An InstallAssistant.pkg the user already has.
        case package(URL)

        var name: String {
            switch self {
            case .catalog: return "Apple catalog"
            case .softwareUpdate: return "Software Update"
            case .application: return "Local installer"
            case .package: return "Local package"
            }
        }
    }

    // As Apple titles it: "macOS Tahoe", "macOS Ventura".
    let name: String
    let version: MacOSVersion
    let build: String
    let sizeBytes: Int64
    // The oldest macOS this installer's package will install onto, taken from
    // the catalog's own volume-check. Nil when the origin does not say.
    let minimumHostVersion: MacOSVersion?
    let origin: Origin

    // Two catalog products can carry the same version and build for different
    // hardware, so the origin has to take part in identity.
    var id: String {
        switch origin {
        case .catalog(let productID, _): return "catalog:\(productID)"
        case .softwareUpdate: return "softwareupdate:\(version)-\(build)"
        case .application(let url): return "application:\(url.path)"
        case .package(let url): return "package:\(url.path)"
        }
    }

    var title: String {
        "\(name) \(version)"
    }

    // One line under the title in the version list.
    var summary: String {
        var parts = ["Build \(build)"]
        if sizeBytes > 0 { parts.append(sizeBytes.formattedSize) }
        parts.append(origin.name)
        return parts.joined(separator: " · ")
    }

    // Where the installer application ends up. `installer` and `softwareupdate`
    // both write into /Applications under Apple's own naming; a local one is
    // already wherever the user keeps it.
    var applicationURL: URL {
        switch origin {
        case .application(let url):
            return url
        case .catalog, .softwareUpdate, .package:
            return URL(fileURLWithPath: "/Applications/Install \(name).app")
        }
    }
}
