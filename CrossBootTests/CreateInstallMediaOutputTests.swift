import XCTest
@testable import CrossBoot

// createinstallmedia offers no machine-readable progress, so the bar is driven
// by re-reading its log. It writes percentages as dots on one unterminated line,
// which is why the whole text is parsed rather than the newest line.
final class CreateInstallMediaOutputTests: XCTestCase {

    func testEachStepIsRecognisedFromItsMarker() {
        XCTAssertEqual(CreateInstallMediaOutput.read("CrossBoot: preparing")?.phase, .preparing)
        XCTAssertEqual(CreateInstallMediaOutput.read("CrossBoot: preparing\nCrossBoot: erasing")?.phase, .erasing)
        XCTAssertEqual(CreateInstallMediaOutput.read("CrossBoot: erasing\nCrossBoot: writing")?.phase, .writing)
        XCTAssertEqual(CreateInstallMediaOutput.read("CrossBoot: writing\nCrossBoot: finished")?.phase, .finished)
        XCTAssertEqual(CreateInstallMediaOutput.read("CrossBoot: writing\nCrossBoot: stopped")?.phase, .stopped)
    }

    func testOutputWithNoMarkerReportsNothing() {
        XCTAssertNil(CreateInstallMediaOutput.read(""))
        XCTAssertNil(CreateInstallMediaOutput.read("Password:"))
    }

    // The figure that counts is the last one written, not the first.
    func testTheLatestPercentageOnALineIsTheOneRead() {
        XCTAssertEqual(CreateInstallMediaOutput.lastPercent(in: " 0%... 10%... 20%..."), 20)
        XCTAssertEqual(CreateInstallMediaOutput.lastPercent(in: " 0%... 100%"), 100)
        XCTAssertEqual(CreateInstallMediaOutput.lastPercent(in: " no percentages here"), 0)
    }

    // A real run only ever moves forward through these lines.
    func testTheWritingPhaseNeverGoesBackwardsThroughARealRun() throws {
        let steps = [
            "CrossBoot: preparing",
            "CrossBoot: preparing\ninstaller: Installing at base path /",
            "CrossBoot: preparing\nCrossBoot: erasing",
            "CrossBoot: erasing\nStarted erase on disk4\nFinished erase on disk4\nCrossBoot: writing",
            "CrossBoot: writing\nErasing disk: 0%... 50%...",
            "CrossBoot: writing\nErasing disk: 0%... 50%... 100%",
            "CrossBoot: writing\nErasing disk: 100%\nCopying to disk: 0%... 10%...",
            "CrossBoot: writing\nErasing disk: 100%\nCopying to disk: 0%... 90%...",
            "CrossBoot: writing\nCopying to disk: 100%\nMaking disk bootable...",
            "CrossBoot: writing\nMaking disk bootable...\nInstall media now available at \"/Volumes/Install macOS Tahoe\"",
            "CrossBoot: writing\nInstall media now available\nCrossBoot: finished"
        ]

        var previous = -1.0
        for step in steps {
            let report = try XCTUnwrap(CreateInstallMediaOutput.read(step), "no report for: \(step)")
            guard report.phase == .writing || report.phase == .finished else { continue }

            XCTAssertGreaterThanOrEqual(report.fraction, previous, "progress went backwards at: \(step)")
            previous = report.fraction
        }

        XCTAssertEqual(previous, 1)
    }

    // Current releases print nothing at all between starting the copy and
    // finishing it, so what the step samples off the drive is what moves the bar.
    func testTheCopyIsMeasuredFromWhatIsOnTheDrive() throws {
        let installer: Int64 = 15_000_000_000
        let silent = """
        CrossBoot: writing
        Erasing disk: 0%... 100%
        Copying essential files...
        """

        let started = try XCTUnwrap(CreateInstallMediaOutput.read(silent, expecting: installer))
        let quarter = try XCTUnwrap(CreateInstallMediaOutput.read(
            silent + "\nCrossBoot: copied 3662109", expecting: installer
        ))
        let most = try XCTUnwrap(CreateInstallMediaOutput.read(
            silent + "\nCrossBoot: copied 3662109\nCrossBoot: copied 12000000", expecting: installer
        ))

        XCTAssertEqual(quarter.fraction, 0.25, accuracy: 0.01)
        XCTAssertGreaterThan(most.fraction, quarter.fraction)
        XCTAssertLessThan(started.fraction, quarter.fraction)
    }

    // A sample bigger than the installer - the volume holds more than its files -
    // must not run the bar to the end before the drive is bootable.
    func testAnOverlargeSampleStopsShortOfTheEnd() throws {
        let report = try XCTUnwrap(CreateInstallMediaOutput.read(
            "CrossBoot: writing\nCrossBoot: copied 99999999", expecting: 15_000_000_000
        ))

        XCTAssertEqual(report.fraction, 0.95)
    }

    // Every source of a figure can stall; the bar follows whichever of them has
    // got furthest, so one going quiet cannot stop it.
    func testTheFurthestSourceIsTheOneFollowed() throws {
        let installer: Int64 = 15_000_000_000
        let stalled = """
        CrossBoot: writing
        Erasing disk: 0%... 100%
        Copying essential files...
        CrossBoot: copied 1000000
        Copying the macOS RecoveryOS...
        """

        let report = try XCTUnwrap(CreateInstallMediaOutput.read(stalled, expecting: installer))

        // The samples stopped at a fifteenth of the installer; the tool's own
        // last line says the copy is nearly done.
        XCTAssertEqual(report.fraction, 0.9, accuracy: 0.001)
    }

    // A run of a release that prints nothing but these lines still moves.
    func testTheToolsOwnLinesMoveTheBarOnTheirOwn() throws {
        let steps = [
            "CrossBoot: writing\nErasing disk: 0%... 100%",
            "CrossBoot: writing\nErasing disk: 100%\nCopying essential files...",
            "CrossBoot: writing\nCopying essential files...\nCopying the macOS RecoveryOS...",
            "CrossBoot: writing\nCopying the macOS RecoveryOS...\nMaking disk bootable..."
        ]

        var previous = -1.0
        for step in steps {
            let report = try XCTUnwrap(CreateInstallMediaOutput.read(step))
            XCTAssertGreaterThan(report.fraction, previous, "did not move at: \(step)")
            previous = report.fraction
        }
    }

    func testTheLastSampleIsTheOneRead() {
        XCTAssertEqual(CreateInstallMediaOutput.lastCopiedBytes(in: "CrossBoot: copied 10\nCrossBoot: copied 20"), 20 * 1024)
        XCTAssertNil(CreateInstallMediaOutput.lastCopiedBytes(in: "Copying essential files..."))
    }

    // Copying is nearly all of the wall clock, so it has to own most of the bar.
    func testCopyingOwnsMostOfTheStep() throws {
        let erasing = try XCTUnwrap(CreateInstallMediaOutput.read("CrossBoot: writing\nErasing disk: 100%"))
        let halfCopied = try XCTUnwrap(CreateInstallMediaOutput.read("CrossBoot: writing\nCopying to disk: 50%"))
        let copied = try XCTUnwrap(CreateInstallMediaOutput.read("CrossBoot: writing\nCopying to disk: 100%"))

        XCTAssertLessThan(erasing.fraction, halfCopied.fraction)
        XCTAssertLessThan(halfCopied.fraction, copied.fraction)
        XCTAssertGreaterThan(copied.fraction - halfCopied.fraction, erasing.fraction)
    }

    // The log is re-read whole on every poll, so the same text arrives repeatedly.
    func testReadingTheSameOutputTwiceReportsTheSameThing() {
        let output = "CrossBoot: writing\nCopying to disk: 0%... 40%..."

        XCTAssertEqual(CreateInstallMediaOutput.read(output), CreateInstallMediaOutput.read(output))
    }
}
