import XCTest
@testable import CrossBoot

final class DiskParsingTests: XCTestCase {

    private func plist(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>
        """
    }

    func testExtractsDeviceIdentifiersInOrder() {
        let output = plist("""
        <dict>
            <key>AllDisksAndPartitions</key>
            <array>
                <dict><key>DeviceIdentifier</key><string>disk4</string></dict>
                <dict><key>DeviceIdentifier</key><string>disk10</string></dict>
            </array>
        </dict>
        """)

        XCTAssertEqual(DiskManager.parseDiskIdentifiers(output), ["disk4", "disk10"])
    }

    func testSkipsEntriesWithoutAnIdentifier() {
        let output = plist("""
        <dict>
            <key>AllDisksAndPartitions</key>
            <array>
                <dict><key>Size</key><integer>1</integer></dict>
                <dict><key>DeviceIdentifier</key><string>disk4</string></dict>
            </array>
        </dict>
        """)

        XCTAssertEqual(DiskManager.parseDiskIdentifiers(output), ["disk4"])
    }

    func testReturnsEmptyWhenNoDisksAreListed() {
        let output = plist("<dict><key>AllDisksAndPartitions</key><array/></dict>")

        XCTAssertEqual(DiskManager.parseDiskIdentifiers(output), [])
    }

    // A failure here must not be mistaken for "no drives are attached".
    func testReturnsEmptyForUnparseableOutput() {
        XCTAssertEqual(DiskManager.parseDiskIdentifiers("not a plist"), [])
        XCTAssertEqual(DiskManager.parseDiskIdentifiers(""), [])
    }
}
