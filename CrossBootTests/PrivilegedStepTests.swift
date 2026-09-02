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
            cancel: URL(fileURLWithPath: "/tmp/work/cancel"),
            ready: URL(fileURLWithPath: "/tmp/work/ready"),
            heartbeat: URL(fileURLWithPath: "/tmp/work/heartbeat"),
            accessProbe: "/tmp/work/probe"
        )
    }

    // The shell script reads positional parameters, so the order is the contract.
    func testArgumentsArriveInThePositionsTheScriptReads() {
        let arguments = argv(request())

        XCTAssertEqual(arguments, [
            "/tmp/work/run.sh",
            "/tmp/work/run.log",
            "/tmp/work/cancel",
            "/tmp/work/ready",
            "/tmp/work/heartbeat",
            "/tmp/work/probe",
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
        XCTAssertEqual(argv(request(preparation: .fetch(version: "13.7.8")))[6...7].map { $0 }, ["fetch", "13.7.8"])
        XCTAssertEqual(argv(request(preparation: .application))[6...7].map { $0 }, ["application", ""])
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

    // Every value reaches the step as one item of the child's argv, so there is
    // no command line for a volume name to break out of.
    func testTheStepIsRunFromArgumentsRatherThanACommandLine() {
        let hostile = "a\"b $(id) `id` ; rm -rf /"

        XCTAssertEqual(argv(request(volume: hostile)).filter { $0 == hostile }.count, 1)
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

    // MARK: - Waiting for the download

    // The password is asked for when the run starts, so the step parks itself
    // until the app says the installer is there. Everything below runs the real
    // script: none of it reaches a command that needs root, because the step
    // gives up on the missing installer application first.
    func testTheStepWaitsBeforeItTouchesTheDrive() throws {
        let script = PrivilegedRunner.script

        let wait = try XCTUnwrap(script.range(of: "while [ ! -e \"$READY\" ]"))
        let erase = try XCTUnwrap(script.range(of: "eraseDisk"))
        let prepare = try XCTUnwrap(script.range(of: "installer -pkg"))

        XCTAssertLessThan(wait.lowerBound, prepare.lowerBound)
        XCTAssertLessThan(wait.lowerBound, erase.lowerBound)
    }

    // The bless at the end is what needs Full Disk Access, and the drive is
    // erased long before it. The step therefore asks first and erases nothing.
    func testTheStepGivesUpBeforeErasingWhenItHasNoFullDiskAccess() throws {
        XCTAssertEqual(try runScript(ready: true, access: false), 77)
    }

    func testTheAccessCheckComesBeforeAnythingIsTouched() throws {
        let script = PrivilegedRunner.script

        let check = try XCTUnwrap(script.range(of: "! -r \"$ACCESS\""))
        let wait = try XCTUnwrap(script.range(of: "while [ ! -e \"$READY\" ]"))
        let erase = try XCTUnwrap(script.range(of: "eraseDisk"))

        XCTAssertLessThan(check.lowerBound, wait.lowerBound)
        XCTAssertLessThan(check.lowerBound, erase.lowerBound)
    }

    func testTheStepRunsOnceTheDownloadIsReady() throws {
        // 66 is the step's own "this is not an installer application", which is
        // the first thing it checks after the wait.
        XCTAssertEqual(try runScript(ready: true), 66)
    }

    func testAStepWaitingOnADownloadStopsWhenTheRunIsCancelled() throws {
        XCTAssertEqual(try runScript(ready: false, cancel: true), 130)
    }

    // Nothing else ends the wait if the app is killed while it downloads, and
    // the step is running as root.
    func testAStepWaitingOnAnAppThatStoppedAnsweringGivesUp() throws {
        XCTAssertEqual(try runScript(ready: false, heartbeat: Date(timeIntervalSinceNow: -600)), 75)
        XCTAssertEqual(try runScript(ready: false, heartbeat: nil), 75)
    }

    // Runs the privileged script itself, unprivileged, with a drive it will
    // never reach.
    private func runScript(
        ready: Bool,
        cancel: Bool = false,
        heartbeat: Date? = Date(),
        access: Bool = true
    ) throws -> Int32 {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crossboot-step-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("run.sh")
        let logURL = directory.appendingPathComponent("run.log")
        let cancelURL = directory.appendingPathComponent("cancel")
        let readyURL = directory.appendingPathComponent("ready")
        let heartbeatURL = directory.appendingPathComponent("heartbeat")
        // Stands in for TCC's database: readable when the step would be allowed
        // to finish, missing when it would not.
        let accessURL = directory.appendingPathComponent("access")

        try PrivilegedRunner.script.write(to: scriptURL, atomically: true, encoding: .utf8)

        if access { FileManager.default.createFile(atPath: accessURL.path, contents: nil) }

        if ready { FileManager.default.createFile(atPath: readyURL.path, contents: nil) }
        if cancel { FileManager.default.createFile(atPath: cancelURL.path, contents: nil) }
        if let heartbeat {
            FileManager.default.createFile(atPath: heartbeatURL.path, contents: nil)
            try FileManager.default.setAttributes(
                [.modificationDate: heartbeat],
                ofItemAtPath: heartbeatURL.path
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            logURL.path,
            cancelURL.path,
            readyURL.path,
            heartbeatURL.path,
            accessURL.path,
            "application",
            "",
            directory.appendingPathComponent("Install macOS Nothing.app").path,
            "/dev/null",
            "CrossBoot-TEST",
            "0",
            "no"
        ]

        try process.run()
        process.waitUntilExit()

        return process.terminationStatus
    }
}
