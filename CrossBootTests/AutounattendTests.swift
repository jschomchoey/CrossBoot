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

    private func write(
        requirements: Bool,
        onlineAccount: Bool,
        architecture: WindowsArchitecture = .x64
    ) async throws -> String {
        try await ISOHandler.shared.createAutounattend(
            at: directory.path,
            architecture: architecture,
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

    // Setup ignores a component whose processorArchitecture does not match the
    // WinPE running it, so an amd64 answer file on ARM64 media is a bypass that
    // silently does nothing.
    func testEveryComponentDeclaresTheMediaArchitecture() async throws {
        let arm = try await write(requirements: true, onlineAccount: true, architecture: .arm64)

        assertWellFormed(arm)
        XCTAssertFalse(arm.contains("amd64"))

        let document = try XMLDocument(xmlString: arm, options: [])
        let components = try document.nodes(forXPath: "//*[local-name()='component']")
        XCTAssertEqual(components.count, 2)

        for component in components {
            let element = try XCTUnwrap(component as? XMLElement)
            XCTAssertEqual(element.attribute(forName: "processorArchitecture")?.stringValue, "arm64")
        }
    }

    func testIntelMediaStillDeclaresAmd64() async throws {
        let intel = try await write(requirements: true, onlineAccount: false, architecture: .x64)

        assertWellFormed(intel)
        XCTAssertTrue(intel.contains(#"processorArchitecture="amd64""#))
    }

    func testNeitherBypassStillProducesValidXML() async throws {
        let xml = try await write(requirements: false, onlineAccount: false)

        assertWellFormed(xml)
        XCTAssertFalse(xml.contains("<settings"))
    }
}
