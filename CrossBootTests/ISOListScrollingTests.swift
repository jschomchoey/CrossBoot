import XCTest
import SwiftUI
import AppKit
@testable import CrossBoot

// The list is held to three rows, so everything past the third one is only
// reachable by scrolling. A `List` put there instead is set up by SwiftUI as
// inline form content - AppKit reports its scroll view with no scroller and no
// elasticity - and a fourth ISO was drawn where nothing could reach it.
@MainActor
final class ISOListScrollingTests: XCTestCase {

    private func page(withISOs count: Int) throws -> NSHostingView<some View> {
        let model = CrossBootViewModel()

        for index in 0..<count {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Scrolling_\(index).iso")
            try Data().write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }

            model.isoFiles.append(try ISOFile(
                url: url,
                installImage: InstallImage(relativePath: "sources/install.wim", sizeBytes: 5_000_000_000, compression: .lzx),
                images: [WindowsImage(index: 1, name: "Windows 11 Pro", architecture: .x64, build: 26100, totalBytes: 0)],
                hasBootLoader: true
            ))
        }

        let hosting = NSHostingView(
            rootView: ContentView(viewModel: model).frame(width: WindowLayout.width)
        )
        // The list is only built once the page is in a window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WindowLayout.width, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()

        return hosting
    }

    // The page's own scroll view is as tall as the page; the list's is the
    // short one inside it.
    private func listScrollView(in view: NSView) throws -> NSScrollView {
        var found: [NSScrollView] = []

        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            view.subviews.forEach(walk)
        }
        walk(view)

        return try XCTUnwrap(found.min { $0.contentView.bounds.height < $1.contentView.bounds.height })
    }

    func testTheISOsPastTheThirdCanBeScrolledTo() throws {
        let list = try listScrollView(in: try page(withISOs: 6))
        let visible = list.contentView.bounds.height - list.contentInsets.bottom
        let content = try XCTUnwrap(list.documentView).frame.height

        XCTAssertGreaterThan(content, visible, "six ISOs have to be taller than the three the list shows")
        XCTAssertTrue(list.hasVerticalScroller, "nothing says the rest of the list is there")
        XCTAssertNotEqual(list.verticalScrollElasticity, .none, "the rows below the third cannot be reached")
    }

    // Three ISOs are what the list is sized for, so they must not need scrolling.
    func testThreeISOsFitWithoutScrolling() throws {
        let list = try listScrollView(in: try page(withISOs: 3))
        let visible = list.contentView.bounds.height - list.contentInsets.bottom
        let content = try XCTUnwrap(list.documentView).frame.height

        XCTAssertLessThanOrEqual(content, visible)
    }
}
