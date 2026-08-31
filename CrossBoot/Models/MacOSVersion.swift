import Foundation

// A macOS version as Apple writes it in a software update catalog: "26.6.2",
// "13.7.8", "10.15.7". Comparison has to be numeric per component - "26.6.2"
// sorts below "26.10" as text and above it as a version.
struct MacOSVersion: Hashable, Comparable, CustomStringConvertible {
    let components: [Int]

    init(_ components: [Int]) {
        self.components = components
    }

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }

        self.components = values
    }

    // Big Sur renumbered macOS from 10.x to 11, and Apple Silicon has never
    // been supported by anything below it.
    var major: Int { components.first ?? 0 }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: MacOSVersion, rhs: MacOSVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0

            if left != right { return left < right }
        }

        return false
    }

    // Trailing zeroes are not significant, so 26.6 and 26.6.0 are one version.
    static func == (lhs: MacOSVersion, rhs: MacOSVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var significant = components
        while significant.count > 1, significant.last == 0 {
            significant.removeLast()
        }
        hasher.combine(significant)
    }

    // Read once: the version list asks for this on every redraw, and it cannot
    // change while the app is running.
    static let host: MacOSVersion = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MacOSVersion([version.majorVersion, version.minorVersion, version.patchVersion])
    }()
}
