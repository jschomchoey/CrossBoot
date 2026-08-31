import Foundation

// Lists the macOS versions Apple still publishes, read from the software update
// catalog rather than from this Mac.
//
// `softwareupdate --list-full-installers` answers with what Apple serves this
// particular machine, which is why it cannot offer a version newer than the one
// this Mac is entitled to. The catalog is not filtered that way: it carries every
// InstallAssistant package Apple publishes, so both older and newer releases are
// reachable, and each entry says for itself which Macs can build it.
actor SoftwareCatalog {
    static let shared = SoftwareCatalog()

    // One catalog product that ships a full installer.
    struct Product: Equatable {
        let identifier: String
        let packageURL: URL
        let sizeBytes: Int64
        let distributionURL: URL
    }

    private var cached: [MacOSInstaller]?

    private init() {}

    func installers(refresh: Bool = false) async throws -> [MacOSInstaller] {
        if !refresh, let cached { return cached }

        let catalog = try await catalogData()
        let products = Self.products(in: catalog)

        guard !products.isEmpty else { throw CatalogError.empty }

        let installers = await Self.installers(for: products)

        guard !installers.isEmpty else { throw CatalogError.empty }

        cached = installers
        return installers
    }

    // MARK: - Catalog

    private func catalogData() async throws -> Data {
        var lastError: Error?

        for url in Self.catalogURLs(hostMajor: MacOSVersion.host.major) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                return data
            } catch {
                lastError = error
            }
        }

        throw CatalogError.unreachable(lastError?.localizedDescription)
    }

    // Apple names the merged catalog after every macOS it serves, newest first,
    // so each release adds a new URL and the old ones stop gaining products.
    // The newest one known here is tried after anything the running system
    // implies, and the first that answers wins.
    private static let newestKnownMajor = 26

    private static let legacyIndexes = [
        "15", "14", "13", "12", "10.16", "10.15", "10.14", "10.13", "10.12",
        "10.11", "10.10", "10.9", "mountainlion", "lion", "snowleopard", "leopard"
    ]

    static func catalogURLs(hostMajor: Int) -> [URL] {
        var candidates: [[String]] = []

        if hostMajor > newestKnownMajor {
            let newer = stride(from: hostMajor, to: newestKnownMajor, by: -1).map(String.init)
            candidates.append(newer + [String(newestKnownMajor)] + legacyIndexes)
        }

        candidates.append([String(newestKnownMajor)] + legacyIndexes)
        candidates.append(legacyIndexes)

        return candidates.compactMap { indexes in
            URL(string: "https://swscan.apple.com/content/catalogs/others/index-"
                + indexes.joined(separator: "-")
                + ".merged-1.sucatalog")
        }
    }

    // MARK: - Products

    static func products(in data: Data) -> [Product] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let products = plist["Products"] as? [String: Any] else {
            return []
        }

        return products.compactMap { identifier, value in
            guard let product = value as? [String: Any],
                  let packages = product["Packages"] as? [[String: Any]],
                  let distributions = product["Distributions"] as? [String: String],
                  let distributionText = distributions["English"],
                  let distributionURL = URL(string: distributionText) else {
                return nil
            }

            // A full installer is the one product that ships InstallAssistant.pkg;
            // everything else in the catalog is an update payload.
            guard let package = packages.first(where: {
                ($0["URL"] as? String)?.hasSuffix("InstallAssistant.pkg") == true
            }), let packageText = package["URL"] as? String,
               let packageURL = URL(string: packageText) else {
                return nil
            }

            return Product(
                identifier: identifier,
                packageURL: packageURL,
                sizeBytes: package["Size"] as? Int64 ?? 0,
                distributionURL: distributionURL
            )
        }
    }

    // Each product needs its own distribution file. They are a few kilobytes
    // each, so they are fetched together rather than one at a time.
    private static func installers(for products: [Product]) async -> [MacOSInstaller] {
        let found = await withTaskGroup(of: MacOSInstaller?.self) { group in
            for product in products {
                group.addTask { await installer(for: product) }
            }

            var results: [MacOSInstaller] = []
            for await installer in group {
                if let installer { results.append(installer) }
            }
            return results
        }

        // The catalog republishes a release whenever its metadata changes, so the
        // same version and build can arrive more than once.
        var seen: Set<String> = []
        return found
            .sorted { $0.version > $1.version }
            .filter { seen.insert("\($0.name) \($0.version) \($0.build)").inserted }
    }

    private static func installer(for product: Product) async -> MacOSInstaller? {
        guard let (data, _) = try? await URLSession.shared.data(from: product.distributionURL),
              let distribution = DistributionParser.parse(String(decoding: data, as: UTF8.self)) else {
            return nil
        }

        return MacOSInstaller(
            name: distribution.title,
            version: distribution.version,
            build: distribution.build,
            sizeBytes: product.sizeBytes,
            minimumHostVersion: distribution.minimumHostVersion,
            origin: .catalog(productID: product.identifier, packageURL: product.packageURL)
        )
    }
}

enum CatalogError: LocalizedError, Equatable {
    case unreachable(String?)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "Could not reach Apple's software update catalog\(detail.map { ": \($0)" } ?? ".")"
        case .empty:
            return "Apple's software update catalog listed no macOS installers."
        }
    }
}
