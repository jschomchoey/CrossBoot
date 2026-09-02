import XCTest
@testable import CrossBoot

// The plan is what stands between a wrong choice and an erased drive, so every
// refusal it can raise has to be raised before the run starts.
final class MacOSMediaPlanTests: XCTestCase {

    private func installer(
        _ name: String = "macOS Tahoe",
        _ version: [Int] = [26, 6, 2],
        build: String = "25G83",
        size: Int64 = 18_384_624_402,
        minimumHost: [Int]? = nil,
        origin: MacOSInstaller.Origin = .catalog(
            productID: "140-93587",
            packageURL: URL(fileURLWithPath: "/tmp/InstallAssistant.pkg")
        )
    ) -> MacOSInstaller {
        MacOSInstaller(
            name: name,
            version: MacOSVersion(version),
            build: build,
            sizeBytes: size,
            minimumHostVersion: minimumHost.map(MacOSVersion.init),
            origin: origin
        )
    }

    // MARK: - Versions

    // "26.6.2" sorts below "26.10" as text and above it as a version, and the
    // list is ordered by this.
    func testVersionsCompareNumericallyRatherThanAsText() {
        XCTAssertTrue(MacOSVersion([26, 10]) > MacOSVersion([26, 6, 2]))
        XCTAssertTrue(MacOSVersion([26]) > MacOSVersion([15, 7, 9]))
        XCTAssertTrue(MacOSVersion([11]) > MacOSVersion([10, 15, 7]))
        XCTAssertEqual(MacOSVersion("26.6"), MacOSVersion([26, 6, 0]))
        XCTAssertEqual(MacOSVersion("13.7.8")?.description, "13.7.8")
        XCTAssertNil(MacOSVersion("Tahoe"))
        XCTAssertNil(MacOSVersion(""))
    }

    func testTrailingZeroesDoNotSplitOneVersionInTwo() {
        let padded = MacOSVersion([26, 6, 0])
        let plain = MacOSVersion([26, 6])

        XCTAssertEqual(padded, plain)
        XCTAssertEqual(Set([padded, plain]).count, 1)
    }

    // MARK: - Refusals

    func testAnInstallerNeedingANewerMacOSIsRefused() {
        let plan = MacOSMediaPlan.refusal(
            for: installer(minimumHost: [26, 0]),
            host: MacOSVersion([13, 7, 8]),
            appleSilicon: true
        )

        XCTAssertEqual(plan, .hostTooOld(
            name: "macOS Tahoe 26.6.2",
            required: MacOSVersion([26, 0]),
            host: MacOSVersion([13, 7, 8])
        ))
    }

    func testAnInstallerThisMacCanExpandIsAllowed() {
        XCTAssertNil(MacOSMediaPlan.refusal(
            for: installer(minimumHost: [10, 15]),
            host: MacOSVersion([26, 6, 2]),
            appleSilicon: true
        ))
    }

    // Big Sur was the first macOS on Apple Silicon; older media would write
    // successfully and then boot nothing.
    func testPreBigSurIsRefusedOnAppleSilicon() {
        let refusal = MacOSMediaPlan.refusal(
            for: installer("macOS Catalina", [10, 15, 7]),
            host: MacOSVersion([26, 6, 2]),
            appleSilicon: true
        )

        XCTAssertEqual(refusal, .intelOnly(name: "macOS Catalina 10.15.7"))
    }

    func testPreBigSurIsAllowedOnIntel() {
        XCTAssertNil(MacOSMediaPlan.refusal(
            for: installer("macOS Catalina", [10, 15, 7]),
            host: MacOSVersion([26, 6, 2]),
            appleSilicon: false
        ))
    }

    func testBigSurIsTheFirstReleaseAppleSiliconAccepts() {
        XCTAssertNil(MacOSMediaPlan.refusal(
            for: installer("macOS Big Sur", [11, 7, 10]),
            host: MacOSVersion([26, 6, 2]),
            appleSilicon: true
        ))
    }

    // MARK: - Space

    // Installers run from 12 GB to 18 GB, so a fixed figure would be wrong at
    // both ends.
    func testTheDriveRequirementFollowsTheInstaller() throws {
        let tahoe = try MacOSMediaPlan.make(
            for: installer(size: 18_384_624_402),
            host: MacOSVersion([26, 6, 2]),
            appleSilicon: true
        )
        let ventura = try MacOSMediaPlan.make(
            for: installer("macOS Ventura", [13, 7, 8], size: 12_205_110_942),
            host: MacOSVersion([26, 6, 2]),
            appleSilicon: true
        )

        XCTAssertGreaterThan(tahoe.estimatedDriveBytes, 18_384_624_402)
        XCTAssertGreaterThan(tahoe.estimatedDriveBytes, ventura.estimatedDriveBytes)
        // A 16 GB drive cannot take Tahoe but can take Ventura.
        XCTAssertGreaterThan(tahoe.estimatedDriveBytes, 16_000_000_000)
        XCTAssertLessThan(ventura.estimatedDriveBytes, 16_000_000_000)
    }

    // A download and the application it expands into exist at the same time.
    func testScratchSpaceCoversTheDownloadAndItsExpansion() throws {
        let size: Int64 = 18_384_624_402

        let downloaded = try MacOSMediaPlan.make(for: installer(size: size), appleSilicon: true)
        XCTAssertEqual(downloaded.estimatedTemporaryBytes, size * 2)

        let local = try MacOSMediaPlan.make(
            for: installer(size: size, origin: .application(URL(fileURLWithPath: "/Applications/Install macOS Tahoe.app"))),
            appleSilicon: true
        )
        XCTAssertEqual(local.estimatedTemporaryBytes, 0, "an installer already on disk costs no scratch space")

        let offered = try MacOSMediaPlan.make(for: installer(size: size, origin: .softwareUpdate), appleSilicon: true)
        XCTAssertEqual(offered.estimatedTemporaryBytes, size)
    }

    // MARK: - Identity

    // The prepared application has to land where createinstallmedia is looked
    // for, and a local one is used exactly where it already is.
    func testTheApplicationPathFollowsTheOrigin() {
        XCTAssertEqual(
            installer().applicationURL.path,
            "/Applications/Install macOS Tahoe.app"
        )

        let elsewhere = URL(fileURLWithPath: "/Volumes/Backup/Install macOS Ventura.app")
        XCTAssertEqual(
            installer(origin: .application(elsewhere)).applicationURL,
            elsewhere
        )
    }

    // The same release reaches the list from the catalog and from softwareupdate;
    // they are different rows and must not collapse into one.
    func testOriginTakesPartInIdentity() {
        XCTAssertNotEqual(installer().id, installer(origin: .softwareUpdate).id)
    }
}

// The progress bar is drawn from what a run actually does. A run with nothing to
// download must not spend a third of the bar not downloading anything, and the
// part that takes the time has to own the part of the bar that shows it.
final class ProgressBarTests: XCTestCase {

    private func bar(_ origin: MacOSInstaller.Origin) -> MacOSMediaBuilder.Bar {
        MacOSMediaBuilder.Bar.forRun(with: origin)
    }

    private var catalog: MacOSInstaller.Origin {
        .catalog(productID: "140-93587", packageURL: URL(fileURLWithPath: "/tmp/InstallAssistant.pkg"))
    }

    // An installer already sitting in /Applications: writing the drive is the
    // whole run, so it gets nearly the whole bar.
    func testAnInstallerOnDiskGivesTheWriteTheWholeBar() {
        let bar = bar(.application(URL(fileURLWithPath: "/Applications/Install macOS Sequoia.app")))

        XCTAssertEqual(bar.downloaded, MacOSMediaBuilder.Bar.checked)
        XCTAssertEqual(bar.prepared, MacOSMediaBuilder.Bar.checked)
        XCTAssertLessThan(bar.erased, 15, "the bar jumps past a tenth of itself before anything slow happens")
    }

    // A download and a write are both tens of minutes, so they share the bar.
    func testADownloadedInstallerSharesTheBarWithTheWrite() {
        let bar = bar(catalog)

        XCTAssertGreaterThan(bar.downloaded, 25)
        XCTAssertLessThan(bar.downloaded, 45)
        XCTAssertGreaterThan(MacOSMediaBuilder.Bar.finished - bar.erased, 45, "the write owns less than half the bar")
    }

    // Expanding a package is minutes of local disk: some of the bar, not a third.
    func testAPackageOnDiskOnlyPaysForExpandingIt() {
        let onDisk = bar(.package(URL(fileURLWithPath: "/tmp/InstallAssistant.pkg")))

        XCTAssertEqual(onDisk.downloaded, MacOSMediaBuilder.Bar.checked)
        XCTAssertGreaterThan(onDisk.prepared, MacOSMediaBuilder.Bar.checked)
        XCTAssertLessThan(onDisk.prepared, bar(catalog).prepared)
    }

    // Whatever the run, the bar only ever moves forward through these points.
    func testEveryRunsBarIsInOrder() {
        let origins: [MacOSInstaller.Origin] = [
            catalog,
            .softwareUpdate,
            .package(URL(fileURLWithPath: "/tmp/InstallAssistant.pkg")),
            .application(URL(fileURLWithPath: "/Applications/Install macOS Sequoia.app"))
        ]

        for origin in origins {
            let points = bar(origin)

            XCTAssertLessThanOrEqual(MacOSMediaBuilder.Bar.checked, points.downloaded, "\(origin)")
            XCTAssertLessThanOrEqual(points.downloaded, points.prepared, "\(origin)")
            XCTAssertLessThanOrEqual(points.prepared, points.erased, "\(origin)")
            XCTAssertLessThan(points.erased, MacOSMediaBuilder.Bar.finished, "\(origin)")
        }
    }
}
