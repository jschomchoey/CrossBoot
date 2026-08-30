import Foundation

// Reads the image list wimlib writes out of a WIM's XML metadata blob.
//
// Windows stores it as UTF-16 with a byte order mark and no XML declaration,
// so the bytes are decoded here rather than handed to the parser directly.
enum WimXMLParser {

    static func images(from data: Data) throws -> [WindowsImage] {
        guard let xml = decode(data) else {
            throw WimLibError.unreadableMetadata
        }

        let document = try XMLDocument(xmlString: xml, options: [])

        return try document.nodes(forXPath: "/WIM/IMAGE").compactMap { node in
            guard let element = node as? XMLElement,
                  let index = Int(element.attribute(forName: "INDEX")?.stringValue ?? "") else {
                return nil
            }

            // DISPLAYNAME is what the setup menu shows when a WIM carries both.
            let name = text(in: element, "DISPLAYNAME")
                ?? text(in: element, "NAME")
                ?? "Image \(index)"

            return WindowsImage(
                index: index,
                name: name,
                architecture: integer(in: element, "WINDOWS/ARCH").flatMap(WindowsArchitecture.init(rawValue:)),
                build: integer(in: element, "WINDOWS/VERSION/BUILD") ?? 0,
                totalBytes: Int64(integer(in: element, "TOTALBYTES") ?? 0)
            )
        }
    }

    private static func text(in element: XMLElement, _ path: String) -> String? {
        guard let node = try? element.nodes(forXPath: path).first,
              let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func integer(in element: XMLElement, _ path: String) -> Int? {
        text(in: element, path).flatMap { Int($0) }
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }

        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }

        return String(data: data, encoding: .utf8)
    }
}
