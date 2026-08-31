import XCTest
@testable import CrossBoot

// The privileged step erases a disk as root. What it is told to erase, and the
// shape of the script that tells it, are the two things worth pinning down
// without raising an authorization prompt.
final class PrivilegedStepTests: XCTestCase {

    private func request(
        preparation: PrivilegedRunner.Preparation = .package(URL(fileURLWithPath: "/tmp/InstallAssistant.pkg")),
        application: String = "/Applications/Install macOS Tahoe.app",
        device: String = "/dev/disk4",
        size: Int64 = 32_000_000_000,
        volume: String = "CrossBoot-A1B2C3D4",
        removesInstaller: Bool = false
    ) -> PrivilegedRunner.Request {
        PrivilegedRunner.Request(
            preparation: preparation,
            applicationURL: URL(fileURLWithPath: application),
            device: device,
            driveSizeBytes: size,
            volumeName: volume,
            removesPreparedInstaller: removesInstaller
        )
    }

    private func argv(_ request: PrivilegedRunner.Request) -> [String] {
        PrivilegedRunner.arguments(
            for: request,
            script: URL(fileURLWithPath: "/tmp/work/run.sh"),
            log: URL(fileURLWithPath: "/tmp/work/run.log"),
            cancel: URL(fileURLWithPath: "/tmp/work/cancel")
        )
    }

    // The shell script reads positional parameters, so the order is the contract.
    func testArgumentsArriveInThePositionsTheScriptReads() {
        let arguments = argv(request())

        XCTAssertEqual(arguments[0], "-e")
        XCTAssertEqual(Array(arguments.dropFirst(2)), [
            "/tmp/work/run.sh",
            "/tmp/work/run.log",
            "/tmp/work/cancel",
            "package",
            "/tmp/InstallAssistant.pkg",
            "/Applications/Install macOS Tahoe.app",
            "/dev/disk4",
            "CrossBoot-A1B2C3D4",
            "32000000000",
            "no"
        ])
    }

    func testEachPreparationNamesItsOwnKindAndSource() {
        XCTAssertEqual(argv(request(preparation: .fetch(version: "13.7.8")))[5...6].map { $0 }, ["fetch", "13.7.8"])
        XCTAssertEqual(argv(request(preparation: .application))[5...6].map { $0 }, ["application", ""])
    }

    func testRemovingThePreparedInstallerIsOptedInto() {
        XCTAssertEqual(argv(request(removesInstaller: false)).last, "no")
        XCTAssertEqual(argv(request(removesInstaller: true)).last, "yes")
    }

    // Nothing the user chose may reach the privileged shell as anything but a
    // value. A volume name is the one field a user can shape freely.
    func testHostileValuesArePassedThroughUnchanged() {
        let hostile = "a\"b $(id) `id` ; rm -rf /"
        let arguments = argv(request(volume: hostile))

        XCTAssertTrue(arguments.contains(hostile), "the value was rewritten before it reached argv")
        // It is one argv item, not something that was split or escaped in place.
        XCTAssertEqual(arguments.filter { $0 == hostile }.count, 1)
    }

    // MARK: - The script itself

    func testTheScriptRefusesTraversalBeforeItRunsAnything() {
        let script = PrivilegedRunner.script

        XCTAssertTrue(script.contains("*..*"), "a path containing .. has to be refused outright")
        // The refusal has to come before the step that removes a directory tree.
        let refusal = try? XCTUnwrap(script.range(of: "*..*"))
        let removal = try? XCTUnwrap(script.range(of: "/bin/rm -rf"))
        if let refusal, let removal {
            XCTAssertLessThan(refusal.lowerBound, removal.lowerBound)
        }
    }

    // The drive was last checked before an authorization prompt and a download
    // that can run for an hour, so the step has to check again as root.
    func testTheScriptRecheckesTheDriveBeforeErasing() throws {
        let script = PrivilegedRunner.script

        let internalCheck = try XCTUnwrap(script.range(of: "field Internal"))
        let sizeCheck = try XCTUnwrap(script.range(of: "field TotalSize"))
        let erase = try XCTUnwrap(script.range(of: "eraseDisk"))

        XCTAssertLessThan(internalCheck.lowerBound, erase.lowerBound)
        XCTAssertLessThan(sizeCheck.lowerBound, erase.lowerBound)
    }

    // Only a bundle this step created may be removed, and only where Apple's
    // own installer puts it.
    func testTheScriptOnlyRemovesAnInstallerItPrepared() {
        let script = PrivilegedRunner.script

        XCTAssertTrue(script.contains("'/Applications/Install macOS'*.app)"))
        XCTAssertTrue(script.contains("[ \"$KIND\" != \"application\" ]"))
        XCTAssertTrue(script.contains("[ -x \"$APP/Contents/Resources/createinstallmedia\" ]"))
    }

    func testTheScriptErasesForCreateInstallMediaNotForWindows() {
        let script = PrivilegedRunner.script

        XCTAssertTrue(script.contains("eraseDisk JHFS+"), "createinstallmedia requires Mac OS Extended (Journaled)")
        XCTAssertTrue(script.contains("GPT"))
        XCTAssertFalse(script.contains("MS-DOS"))
    }
}
