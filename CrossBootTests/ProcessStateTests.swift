import XCTest
@testable import CrossBoot

final class ProcessStateTests: XCTestCase {

    func testOnlyWorkingStagesCountAsProcessing() {
        let working: [ProcessStage] = [.formatting, .analyzing, .splitting, .copying, .aborting]
        for stage in working {
            XCTAssertTrue(ProcessState(stage: stage).isProcessing, "\(stage) should be processing")
        }

        let finished: [ProcessStage] = [.idle, .done, .aborted, .error("boom")]
        for stage in finished {
            XCTAssertFalse(ProcessState(stage: stage).isProcessing, "\(stage) should not be processing")
        }
    }

    // A stale progress value next to an error message reads as partial success.
    func testFailedClearsProgress() {
        let state = ProcessState.failed("disk went away")

        XCTAssertEqual(state.progress, 0)
        XCTAssertFalse(state.isProcessing)
        XCTAssertEqual(state.stage, .error("disk went away"))

        // The finished screen supplies its own "Could not finish" heading, so the
        // stage carries only the message.
        XCTAssertEqual(state.stage.description, "disk went away")
    }


    @MainActor
    func testProgressMapsStagesOntoTheirOwnSlice() {
        // Splitting occupies 5% - 15% of the overall bar.
        XCTAssertEqual(MediaBuilder.overallProgress(0, from: 5, to: 15), 5, accuracy: 0.001)
        XCTAssertEqual(MediaBuilder.overallProgress(50, from: 5, to: 15), 10, accuracy: 0.001)
        XCTAssertEqual(MediaBuilder.overallProgress(100, from: 5, to: 15), 15, accuracy: 0.001)

        // Copying runs to 99% from wherever the previous stage ended.
        XCTAssertEqual(MediaBuilder.overallProgress(0, from: 15, to: 99), 15, accuracy: 0.001)
        XCTAssertEqual(MediaBuilder.overallProgress(100, from: 15, to: 99), 99, accuracy: 0.001)
        XCTAssertEqual(MediaBuilder.overallProgress(100, from: 5, to: 99), 99, accuracy: 0.001)
    }

    // Identifiers get reused across replugs, so identity must cover the whole drive.
    func testDrivesWithTheSameIdentifierAreNotInterchangeable() {
        let original = Drive(id: "disk4", device: "/dev/disk4", name: "SanDisk Ultra", size: 32_000_000_000)
        let replaced = Drive(id: "disk4", device: "/dev/disk4", name: "Kingston DataTraveler", size: 64_000_000_000)
        let resized = Drive(id: "disk4", device: "/dev/disk4", name: "SanDisk Ultra", size: 64_000_000_000)

        XCTAssertNotEqual(original, replaced)
        XCTAssertNotEqual(original, resized)
        XCTAssertEqual(original, Drive(id: "disk4", device: "/dev/disk4", name: "SanDisk Ultra", size: 32_000_000_000))
    }

    func testSizesUseTheSameFormatterEverywhere() {
        let bytes: Int64 = 32_000_000_000
        let drive = Drive(id: "disk4", device: "/dev/disk4", name: "USB", size: bytes)

        XCTAssertEqual(drive.sizeFormatted, bytes.formattedSize)
    }
}
