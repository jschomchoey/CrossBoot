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
    func testProgressNeverGoesBackwardsThroughARealRun() throws {
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
            XCTAssertGreaterThanOrEqual(report.progress, previous, "progress went backwards at: \(step)")
            previous = report.progress
        }

        XCTAssertEqual(previous, 100)
    }

    // Copying is nearly all of the wall clock, so it has to own most of the bar.
    func testCopyingOwnsMostOfTheStep() throws {
        let erasing = try XCTUnwrap(CreateInstallMediaOutput.read("CrossBoot: writing\nErasing disk: 100%"))
        let halfCopied = try XCTUnwrap(CreateInstallMediaOutput.read("CrossBoot: writing\nCopying to disk: 50%"))
        let copied = try XCTUnwrap(CreateInstallMediaOutput.read("CrossBoot: writing\nCopying to disk: 100%"))

        XCTAssertLessThan(erasing.progress, halfCopied.progress)
        XCTAssertLessThan(halfCopied.progress, copied.progress)
        XCTAssertGreaterThan(copied.progress - halfCopied.progress, erasing.progress - 45)
    }

    // The log is re-read whole on every poll, so the same text arrives repeatedly.
    func testReadingTheSameOutputTwiceReportsTheSameThing() {
        let output = "CrossBoot: writing\nCopying to disk: 0%... 40%..."

        XCTAssertEqual(CreateInstallMediaOutput.read(output), CreateInstallMediaOutput.read(output))
    }
}
