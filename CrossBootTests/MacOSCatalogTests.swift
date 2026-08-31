import XCTest
@testable import CrossBoot

// Everything the version list shows comes out of these two files. Apple's
// catalog says only how big a product is and where to get it; the name, the
// version, the build and the oldest macOS that can build it live in the
// distribution beside it.
final class MacOSCatalogTests: XCTestCase {

    // Trimmed from the real 140-93587.English.dist that Apple serves today.
    private static let tahoeDistribution = """
    <?xml version="1.0" encoding="utf-8"?>
    <installer-gui-script minSpecVersion="2">
        <pkg-ref id="InstallAssistant" packageIdentifier="com.apple.pkg.InstallAssistant.macOSTahoe"/>
        <title>macOS Tahoe</title>
        <options visibleOnlyForPredicate="true" customize="false" rootVolumeOnly="true"/>
        <volume-check script="">
            <allowed-os-versions>
                <os-version min="10.15"/>
            </allowed-os-versions>
        </volume-check>
        <auxinfo>
            <dict>
                <key>BUILD</key>
                <string>25G83</string>
                <key>VERSION</key>
                <string>26.6.2</string>
            </dict>
        </auxinfo>
    </installer-gui-script>
    """

    func testReadsTheReleaseOutOfADistribution() throws {
        let distribution = try XCTUnwrap(DistributionParser.parse(Self.tahoeDistribution))

        XCTAssertEqual(distribution.title, "macOS Tahoe")
        XCTAssertEqual(distribution.version, MacOSVersion([26, 6, 2]))
        XCTAssertEqual(distribution.build, "25G83")
        XCTAssertEqual(distribution.minimumHostVersion, MacOSVersion([10, 15]))
    }

    // A product with no volume-check is buildable anywhere, not nowhere.
    func testADistributionWithoutAVolumeCheckHasNoMinimum() throws {
        let trimmed = Self.tahoeDistribution
            .replacingOccurrences(of: "<os-version min=\"10.15\"/>", with: "")

        let distribution = try XCTUnwrap(DistributionParser.parse(trimmed))

        XCTAssertNil(distribution.minimumHostVersion)
        XCTAssertEqual(distribution.version, MacOSVersion([26, 6, 2]))
    }

    func testADistributionWithoutAVersionIsRefused() {
        let broken = Self.tahoeDistribution
            .replacingOccurrences(of: "<string>26.6.2</string>", with: "<string></string>")

        XCTAssertNil(DistributionParser.parse(broken))
    }

    // MARK: - Catalog

    private static func catalog(_ products: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Products</key><dict>\(products)</dict></dict></plist>
        """.utf8)
    }

    private static let fullInstaller = """
    <key>140-93587</key>
    <dict>
        <key>Packages</key>
        <array>
            <dict>
                <key>URL</key><string>https://swcdn.apple.com/x/UpdateBrain.zip</string>
                <key>Size</key><integer>123</integer>
            </dict>
            <dict>
                <key>URL</key><string>https://swcdn.apple.com/x/InstallAssistant.pkg</string>
                <key>Size</key><integer>18384624402</integer>
            </dict>
        </array>
        <key>Distributions</key>
        <dict><key>English</key><string>https://swdist.apple.com/x/140-93587.English.dist</string></dict>
    </dict>
    """

    // Most of the catalog is update payloads; only a product shipping
    // InstallAssistant.pkg is a full installer.
    private static let updateOnly = """
    <key>052-12345</key>
    <dict>
        <key>Packages</key>
        <array>
            <dict>
                <key>URL</key><string>https://swcdn.apple.com/x/SomeUpdate.pkg</string>
                <key>Size</key><integer>500</integer>
            </dict>
        </array>
        <key>Distributions</key>
        <dict><key>English</key><string>https://swdist.apple.com/x/052-12345.English.dist</string></dict>
    </dict>
    """

    func testOnlyProductsShippingAFullInstallerAreKept() throws {
        let products = SoftwareCatalog.products(in: Self.catalog(Self.fullInstaller + Self.updateOnly))

        XCTAssertEqual(products.count, 1)

        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(product.identifier, "140-93587")
        XCTAssertEqual(product.sizeBytes, 18_384_624_402)
        XCTAssertEqual(product.packageURL.lastPathComponent, "InstallAssistant.pkg")
        XCTAssertEqual(product.distributionURL.lastPathComponent, "140-93587.English.dist")
    }

    func testAnUnreadableCatalogYieldsNothingRatherThanCrashing() {
        XCTAssertTrue(SoftwareCatalog.products(in: Data("not a plist".utf8)).isEmpty)
        XCTAssertTrue(SoftwareCatalog.products(in: Data()).isEmpty)
    }

    // Apple names the catalog after every macOS it serves, so a release this app
    // predates has to be reachable without shipping a new build.
    func testCatalogURLsLeadWithAnythingNewerThanTheKnownRelease() throws {
        let future = SoftwareCatalog.catalogURLs(hostMajor: 28)
        let first = try XCTUnwrap(future.first?.absoluteString)

        XCTAssertTrue(first.contains("index-28-27-26-15-"), first)
        // The known-good catalog still has to be tried after it.
        XCTAssertTrue(future.contains { $0.absoluteString.contains("index-26-15-14-") })

        let current = SoftwareCatalog.catalogURLs(hostMajor: 26)
        XCTAssertTrue(try XCTUnwrap(current.first?.absoluteString).contains("index-26-15-14-"))
        XCTAssertFalse(current.contains { $0.absoluteString.contains("index-27") })
    }

    // MARK: - softwareupdate

    func testReadsTheInstallersSoftwareUpdateLists() throws {
        let output = """
        Finding available software
        Software Update found the following full installers:
        * Title: macOS Tahoe, Version: 26.6.2, Size: 17953734KiB, Build: 25G83, Deferred: NO
        * Title: macOS Sequoia, Version: 15.7.9, Size: 15289021KiB, Build: 24G830, Deferred: NO
        * Title: macOS Sequoia, Version: 15.7.9, Size: 15289021KiB, Build: 24G830, Deferred: NO
        """

        let installers = InstallerSource.parseFullInstallers(output)

        XCTAssertEqual(installers.count, 2, "the repeated release should be listed once")

        let newest = try XCTUnwrap(installers.first)
        XCTAssertEqual(newest.name, "macOS Tahoe")
        XCTAssertEqual(newest.version, MacOSVersion([26, 6, 2]))
        XCTAssertEqual(newest.build, "25G83")
        XCTAssertEqual(newest.sizeBytes, 17_953_734 * 1024)
        XCTAssertEqual(newest.origin, .softwareUpdate)

        // Newest first, the way the list shows them.
        XCTAssertEqual(installers.map(\.name), ["macOS Tahoe", "macOS Sequoia"])
    }

    // MARK: - Installers already on this Mac

    // An installer left in /Applications by an earlier run is 12-18 GB that has
    // already been paid for, so the list has to find it without being told.
    func testInstallersAlreadyInApplicationsAreFound() throws {
        let applications = try makeApplicationsDirectory()
        try makeInstaller(named: "Install macOS Sequoia", version: "15.7.9", build: "24G818", in: applications)

        let found = InstallerSource.installedApplications(in: applications)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.name, "macOS Sequoia")
        XCTAssertEqual(found.first?.version, MacOSVersion([15, 7, 9]))
        XCTAssertEqual(found.first?.build, "24G818")
        XCTAssertEqual(found.first?.origin.isOnDisk, true)
    }

    // Everything else in /Applications is somebody's ordinary app, and a folder
    // that only looks like an installer cannot write a drive.
    func testOnlyRealInstallerApplicationsAreFound() throws {
        let applications = try makeApplicationsDirectory()
        try makeInstaller(named: "Install macOS Sequoia", version: "15.7.9", build: "24G818", in: applications)
        try makeInstaller(named: "Safari", version: "26.0", build: "25A354", in: applications)
        try makeInstaller(
            named: "Install macOS Hollow",
            version: "15.0",
            build: "24A335",
            in: applications,
            createInstallMedia: false
        )

        XCTAssertEqual(InstallerSource.installedApplications(in: applications).map(\.name), ["macOS Sequoia"])
    }

    func testNothingIsFoundWhereThereIsNothingToFind() throws {
        let applications = try makeApplicationsDirectory()

        XCTAssertTrue(InstallerSource.installedApplications(in: applications).isEmpty)
        XCTAssertTrue(InstallerSource.installedApplications(in: applications.appendingPathComponent("gone")).isEmpty)
    }

    private func makeApplicationsDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crossboot-applications-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        return directory
    }

    private func makeInstaller(
        named name: String,
        version: String,
        build: String,
        in directory: URL,
        createInstallMedia: Bool = true
    ) throws {
        let contents = directory
            .appendingPathComponent("\(name).app")
            .appendingPathComponent("Contents")
        let shared = contents.appendingPathComponent("SharedSupport")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        if createInstallMedia {
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: resources.appendingPathComponent("createinstallmedia").path,
                contents: nil
            )
        }

        try write(
            ["CFBundleDisplayName": name],
            to: contents.appendingPathComponent("Info.plist")
        )

        try write(
            ["Assets": [["OSVersion": version, "Build": build]]],
            to: shared.appendingPathComponent("com_apple_MobileAsset_MacSoftwareUpdate.xml")
        )
    }

    private func write(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    func testNonListingOutputProducesNoInstallers() {
        XCTAssertTrue(InstallerSource.parseFullInstallers("").isEmpty)
        XCTAssertTrue(InstallerSource.parseFullInstallers("Finding available software\nNo updates.").isEmpty)
    }
}
