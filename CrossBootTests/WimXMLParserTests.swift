import XCTest
@testable import CrossBoot

// wimlib hands back Windows' own XML blob: UTF-16, byte order mark, no
// declaration. Getting the decoding wrong turns every ISO into "unreadable".
final class WimXMLParserTests: XCTestCase {

    private static let sample = """
    <WIM>\
    <IMAGE INDEX="1">\
    <NAME>Windows 11 Home</NAME>\
    <TOTALBYTES>16000000000</TOTALBYTES>\
    <WINDOWS><ARCH>9</ARCH><VERSION><MAJOR>10</MAJOR><BUILD>26100</BUILD></VERSION></WINDOWS>\
    </IMAGE>\
    <IMAGE INDEX="6">\
    <NAME>Windows 11 Pro</NAME>\
    <DISPLAYNAME>Windows 11 Pro (display)</DISPLAYNAME>\
    <WINDOWS><ARCH>12</ARCH><VERSION><BUILD>26100</BUILD></VERSION></WINDOWS>\
    </IMAGE>\
    </WIM>
    """

    private func utf16LE(_ xml: String) throws -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(xml.data(using: .utf16LittleEndian)))
        return data
    }

    func testReadsEveryImageOutOfUTF16Metadata() throws {
        let images = try WimXMLParser.images(from: try utf16LE(Self.sample))

        XCTAssertEqual(images.count, 2)

        let home = try XCTUnwrap(images.first)
        XCTAssertEqual(home.index, 1)
        XCTAssertEqual(home.name, "Windows 11 Home")
        XCTAssertEqual(home.architecture, .x64)
        XCTAssertEqual(home.build, 26100)
        XCTAssertEqual(home.totalBytes, 16_000_000_000)
    }

    // The index is what wimlib is told to export, so it has to come from the
    // attribute and never from the position in the list.
    func testUsesTheDeclaredIndexRatherThanThePosition() throws {
        let images = try WimXMLParser.images(from: try utf16LE(Self.sample))

        XCTAssertEqual(images.last?.index, 6)
        XCTAssertEqual(images.last?.architecture, .arm64)
    }

    func testPrefersTheDisplayNameSetupWouldShow() throws {
        let images = try WimXMLParser.images(from: try utf16LE(Self.sample))

        XCTAssertEqual(images.last?.name, "Windows 11 Pro (display)")
    }

    func testPlainUTF8MetadataStillParses() throws {
        let data = try XCTUnwrap(Self.sample.data(using: .utf8))

        XCTAssertEqual(try WimXMLParser.images(from: data).count, 2)
    }

    func testMissingVersionLeavesTheBuildUnknownRatherThanFailing() throws {
        let xml = #"<WIM><IMAGE INDEX="1"><NAME>Windows PE</NAME></IMAGE></WIM>"#
        let images = try WimXMLParser.images(from: try utf16LE(xml))

        XCTAssertEqual(images.first?.build, 0)
        XCTAssertNil(images.first?.architecture)
        // Without a build there is nothing to disambiguate with, so the name
        // has to survive into the setup menu unchanged.
        XCTAssertEqual(images.first?.mergedName, "Windows PE")
    }

    func testGarbageIsReportedRatherThanReturnedEmpty() {
        XCTAssertThrowsError(try WimXMLParser.images(from: Data([0x00, 0x01, 0x02])))
    }
}
