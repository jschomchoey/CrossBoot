import Foundation

// Reads the `.dist` file Apple publishes beside every macOS installer product.
//
// The catalog entry itself only carries a download URL and a byte count; the
// name, version, build and the oldest macOS the package will install onto all
// live in this file, so nothing can be listed without it.
enum DistributionParser {
    struct Distribution: Equatable {
        // As Apple titles it: "macOS Tahoe".
        let title: String
        let version: MacOSVersion
        let build: String
        // From the distribution's own volume-check. This is what decides whether
        // this Mac can expand the package at all.
        let minimumHostVersion: MacOSVersion?
    }

    static func parse(_ xml: String) -> Distribution? {
        guard let title = value(in: xml, between: "<title>", and: "</title>"),
              let auxiliary = auxiliaryInfo(in: xml),
              let versionText = auxiliary["VERSION"],
              let version = MacOSVersion(versionText),
              let build = auxiliary["BUILD"] else {
            return nil
        }

        return Distribution(
            title: decodeEntities(title),
            version: version,
            build: build,
            minimumHostVersion: minimumHostVersion(in: xml)
        )
    }

    // `auxinfo` wraps a bare plist dictionary, which is worth handing to the
    // plist reader rather than scanning for keys by hand.
    private static func auxiliaryInfo(in xml: String) -> [String: String]? {
        guard let dictionary = value(in: xml, between: "<auxinfo>", and: "</auxinfo>") else { return nil }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">\(dictionary)</plist>
        """

        guard let data = plist.data(using: .utf8),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        return parsed.compactMapValues { $0 as? String }
    }

    // <volume-check><allowed-os-versions><os-version min="10.15"/>
    private static func minimumHostVersion(in xml: String) -> MacOSVersion? {
        guard let allowed = value(in: xml, between: "<allowed-os-versions>", and: "</allowed-os-versions>"),
              let minimum = value(in: allowed, between: "min=\"", and: "\"") else {
            return nil
        }

        return MacOSVersion(minimum)
    }

    private static func value(in text: String, between opening: String, and closing: String) -> String? {
        guard let start = text.range(of: opening),
              let end = text.range(of: closing, range: start.upperBound..<text.endIndex) else {
            return nil
        }

        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
