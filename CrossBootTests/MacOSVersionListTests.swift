import XCTest
@testable import CrossBoot

// The version list is merged from four sources - Apple's catalog, softwareupdate,
// /Applications and whatever the user pointed at - and the same release usually
// arrives from more than one of them.
@MainActor
final class MacOSVersionListTests: XCTestCase {

    private func installer(
        _ name: String = "macOS Sequoia",
        _ version: [Int] = [15, 7, 9],
        build: String = "24G818",
        origin: MacOSInstaller.Origin
    ) -> MacOSInstaller {
        MacOSInstaller(
            name: name,
            version: MacOSVersion(version),
            build: build,
            sizeBytes: 15_000_000_000,
            minimumHostVersion: nil,
            origin: origin
        )
    }

    private var catalogOrigin: MacOSInstaller.Origin {
        .catalog(productID: "140-93587", packageURL: URL(fileURLWithPath: "/tmp/InstallAssistant.pkg"))
    }

    private var applicationOrigin: MacOSInstaller.Origin {
        .application(URL(fileURLWithPath: "/Applications/Install macOS Sequoia.app"))
    }

    // The whole point of reading /Applications: a release already sitting there
    // must not be offered as an 18 GB download.
    func testAReleaseAlreadyOnDiskIsPreferredToTheSameOneInTheCatalog() {
        let model = CrossBootViewModel()
        model.offeredInstallers = [
            installer(origin: catalogOrigin),
            installer(origin: applicationOrigin)
        ]

        model.refreshVersionList()

        XCTAssertEqual(model.macOSVersions.count, 1)
        XCTAssertEqual(model.macOSVersions.first?.origin, applicationOrigin)
    }

    // Whichever source reported it first, the copy that costs nothing wins.
    func testTheOrderTheSourcesAnsweredInDoesNotDecideIt() {
        let model = CrossBootViewModel()
        model.offeredInstallers = [
            installer(origin: applicationOrigin),
            installer(origin: catalogOrigin)
        ]

        model.refreshVersionList()

        XCTAssertEqual(model.macOSVersions.map(\.origin), [applicationOrigin])
    }

    // Preferring a copy is not reordering the list: it stands where the release
    // stands, newest first.
    func testTheListStaysInTheOrderTheReleasesWereListedIn() {
        let model = CrossBootViewModel()
        model.offeredInstallers = [
            installer("macOS Tahoe", [26, 6, 2], build: "25G83", origin: catalogOrigin),
            installer(origin: catalogOrigin),
            installer(origin: applicationOrigin),
            installer("macOS Ventura", [13, 7, 8], build: "22H730", origin: catalogOrigin)
        ]

        model.refreshVersionList()

        XCTAssertEqual(model.macOSVersions.map(\.title), [
            "macOS Tahoe 26.6.2",
            "macOS Sequoia 15.7.9",
            "macOS Ventura 13.7.8"
        ])
        XCTAssertEqual(model.macOSVersions[1].origin, applicationOrigin)
    }

    // The symptom this came from: an installer expanded on disk called itself
    // "15.7" where Apple's catalog called the same build 15.7.9, so the list
    // offered the release as a download the user had already paid for.
    func testTheSameBuildIsOneReleaseWhateverEachSourceCallsIt() {
        let model = CrossBootViewModel()
        model.offeredInstallers = [
            installer("macOS Sequoia", [15, 7, 9], build: "24G830", origin: catalogOrigin),
            installer("macOS Sequoia", [15, 7], build: "24G830", origin: applicationOrigin)
        ]

        model.refreshVersionList()

        XCTAssertEqual(model.macOSVersions.count, 1)
        XCTAssertEqual(model.macOSVersions.first?.origin, applicationOrigin)
    }

    // Two builds of one version are two different installers, and only one of
    // them is on the disk.
    func testADifferentBuildOfTheSameVersionIsItsOwnEntry() {
        let model = CrossBootViewModel()
        model.offeredInstallers = [
            installer(build: "24G818", origin: applicationOrigin),
            installer(build: "24G830", origin: catalogOrigin)
        ]

        model.refreshVersionList()

        XCTAssertEqual(model.macOSVersions.map(\.build), ["24G818", "24G830"])
    }

    // What the user pointed at is the one thing they can take back out again.
    func testOnlyWhatTheUserAddedCanBeRemoved() {
        let model = CrossBootViewModel()
        let added = installer(
            "macOS Sonoma", [14, 8, 9],
            build: "23J1234",
            origin: .application(URL(fileURLWithPath: "/Volumes/Backup/Install macOS Sonoma.app"))
        )
        model.addedInstallers = [added]
        model.offeredInstallers = [installer(origin: applicationOrigin)]

        model.refreshVersionList()

        XCTAssertTrue(model.isRemovable(added))
        XCTAssertFalse(model.isRemovable(try! XCTUnwrap(model.macOSVersions.first { $0.id != added.id })))
    }
}
