import XCTest
@testable import CrossBoot

final class AutounattendTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("autounattend-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(requirements: Bool, onlineAccount: Bool) async throws -> String {
        try await ISOHandler.shared.createAutounattend(
            at: directory.path,
            bypassRequirements: requirements,
            bypassOnlineAccount: onlineAccount
        )

        return try String(
            contentsOf: directory.appendingPathComponent("autounattend.xml"),
            encoding: .utf8
        )
    }

    // Windows silently ignores a malformed answer file, which is how an
    // undeclared `wcm:` namespace prefix once shipped unnoticed.
    private func assertWellFormed(_ xml: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try XMLDocument(xmlString: xml, options: []), file: file, line: line)
    }

    func testRequirementsBypassEmitsEveryLabConfigKey() async throws {
        let xml = try await write(requirements: true, onlineAccount: false)

        assertWellFormed(xml)
        for key in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck",
                    "BypassCPUCheck", "BypassStorageCheck"] {
            XCTAssertTrue(xml.contains(key), "missing \(key)")
        }
        XCTAssertFalse(xml.contains("BypassNRO"))
    }

    func testOnlineAccountBypassEmitsOnlyItsOwnKey() async throws {
        let xml = try await write(requirements: false, onlineAccount: true)

        assertWellFormed(xml)
        XCTAssertTrue(xml.contains("BypassNRO"))
        XCTAssertFalse(xml.contains("BypassTPMCheck"))
    }

    func testBothBypassesProduceOnePassEach() async throws {
        let xml = try await write(requirements: true, onlineAccount: true)

        assertWellFormed(xml)
        XCTAssertTrue(xml.contains("BypassTPMCheck"))
        XCTAssertTrue(xml.contains("BypassNRO"))

        let document = try XMLDocument(xmlString: xml, options: [])
        let passes = try document.nodes(forXPath: "//*[local-name()='settings']")
        XCTAssertEqual(passes.count, 2)
    }

    func testNeitherBypassStillProducesValidXML() async throws {
        let xml = try await write(requirements: false, onlineAccount: false)

        assertWellFormed(xml)
        XCTAssertFalse(xml.contains("<settings"))
    }
}
