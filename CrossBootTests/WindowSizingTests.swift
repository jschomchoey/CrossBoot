import XCTest
import SwiftUI
import AppKit
@testable import CrossBoot

// The window is one fixed size. The page has to fit inside it and report the
// same height in every state it can reach, whatever is showing in the status
// line, because a scroll-disabled form just clips whatever does not fit.
@MainActor
final class WindowSizingTests: XCTestCase {

    private func fittingHeight(of viewModel: CrossBootViewModel) -> CGFloat {
        let hosting = NSHostingView(
            rootView: ContentView(viewModel: viewModel).frame(width: WindowLayout.width)
        )
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func viewModel(
        withISO: Bool = false,
        drive: Bool = true,
        state: ProcessState = ProcessState(),
        inputError: String? = nil
    ) throws -> CrossBootViewModel {
        let model = CrossBootViewModel()

        if drive {
            model.drives = [
                Drive(id: "disk4", device: "/dev/disk4", name: "SanDisk 3.2Gen1", size: 30_770_000_000)
            ]
            model.selectedDrive = model.drives.first
        }

        if withISO {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Win11_23H2_English_x64.iso")
            try Data().write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            model.isoFile = try ISOFile(url: url)
        }

        model.processState = state
        model.inputError = inputError
        return model
    }

    func testThePageIsTheSameHeightInEveryState() throws {
        let idle = fittingHeight(of: try viewModel())

        XCTAssertGreaterThan(idle, 0, "the page reported no height at all")
        XCTAssertLessThanOrEqual(
            idle, WindowLayout.height,
            "the page wants \(idle)pt but the window is fixed at \(WindowLayout.height)pt"
        )

        let others: [(String, CrossBootViewModel)] = [
            ("no drive attached", try viewModel(drive: false)),
            ("ISO chosen", try viewModel(withISO: true)),
            ("copying", try viewModel(withISO: true, state: ProcessState(stage: .copying, progress: 42))),
            ("stopping", try viewModel(withISO: true, state: ProcessState(stage: .aborting, progress: 42))),
            ("done", try viewModel(withISO: true, state: ProcessState(stage: .done, progress: 100))),
            ("aborted", try viewModel(withISO: true, state: ProcessState(stage: .aborted))),
            ("failed", try viewModel(withISO: true, state: .failed("The drive was disconnected."))),
            ("bad drop", try viewModel(inputError: "notes.txt is not an ISO file"))
        ]

        for (name, model) in others {
            XCTAssertEqual(fittingHeight(of: model), idle, accuracy: 0.5, "height changed in state: \(name)")
        }
    }

    // The status line is the one part that takes arbitrary text, so it is where
    // a resize would creep back in.
    func testALongFailureMessageDoesNotChangeTheHeight() throws {
        let short = fittingHeight(of: try viewModel(state: .failed("Disk went away.")))
        let long = fittingHeight(of: try viewModel(state: .failed("""
            The drive was disconnected while copying sources/install.wim. Reconnect it and run \
            again, and keep it plugged in until the copy reports 100 percent.
            """)))

        XCTAssertEqual(long, short, accuracy: 0.5)
    }
}
