import XCTest
@testable import CrossBoot

// The rate is the one thing on screen that says a download is still moving, so
// it has to answer to what was actually transferred rather than to how often
// URLSession happened to report.
final class TransferRateTests: XCTestCase {

    func testNothingIsReportedUntilAWindowHasBeenMeasured() {
        var rate = TransferRate()

        rate.record(0, at: 0)
        rate.record(5_000_000, at: 0.4)
        rate.record(9_000_000, at: 0.9)

        XCTAssertNil(rate.bytesPerSecond)
        XCTAssertNil(rate.formatted)
    }

    func testTheFirstFigureIsWhatWasMeasured() {
        var rate = TransferRate()

        rate.record(0, at: 0)
        rate.record(20_000_000, at: 1)

        XCTAssertEqual(try XCTUnwrap(rate.bytesPerSecond), 20_000_000, accuracy: 1)
    }

    // A burst or a stall must move the figure without becoming it, or the line
    // reads as a different number every second.
    func testALaterFigureOnlyMovesTowardsWhatWasMeasured() throws {
        var rate = TransferRate()

        rate.record(0, at: 0)
        rate.record(20_000_000, at: 1)
        rate.record(60_000_000, at: 2)

        let measured = try XCTUnwrap(rate.bytesPerSecond)
        XCTAssertGreaterThan(measured, 20_000_000)
        XCTAssertLessThan(measured, 40_000_000)
    }

    // Reports arrive far more often than once per window, and averaging each of
    // them in would weight a fast second by however often it was reported.
    func testReportsInsideAWindowDoNotEachCount() throws {
        var dense = TransferRate()
        var sparse = TransferRate()

        dense.record(0, at: 0)
        sparse.record(0, at: 0)

        for step in 1...10 {
            dense.record(Int64(step) * 2_000_000, at: Double(step) / 10)
        }
        dense.record(20_000_000, at: 1)
        sparse.record(20_000_000, at: 1)

        XCTAssertEqual(try XCTUnwrap(dense.bytesPerSecond), try XCTUnwrap(sparse.bytesPerSecond), accuracy: 1)
    }

    // A resumed transfer counts from further back than the mark, and measuring
    // across that would report a negative rate.
    func testATransferThatCountsBackwardsRestartsTheMeasurement() {
        var rate = TransferRate()

        rate.record(50_000_000, at: 0)
        rate.record(10_000_000, at: 1)

        XCTAssertNil(rate.bytesPerSecond)

        rate.record(30_000_000, at: 2)

        XCTAssertEqual(try? XCTUnwrap(rate.bytesPerSecond), 20_000_000)
    }

    func testTheFigureIsQuotedInTheSameUnitsAsEverySizeInTheApp() {
        var rate = TransferRate()

        rate.record(0, at: 0)
        rate.record(20_000_000, at: 1)

        XCTAssertEqual(rate.formatted, "\(Int64(20_000_000).formattedSize)/s")
    }

    func testAStalledTransferReportsNoRateRatherThanZero() {
        var rate = TransferRate()

        rate.record(0, at: 0)
        rate.record(0, at: 5)

        XCTAssertNil(rate.formatted)
    }
}
