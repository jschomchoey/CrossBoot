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
        isoCount: Int = 0,
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

        for index in 0..<isoCount {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Win11_23H2_English_x64_\(index).iso")
            try Data().write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }

            model.isoFiles.append(try ISOFile(
                url: url,
                installImage: InstallImage(relativePath: "sources/install.wim", sizeBytes: 5_000_000_000, compression: .lzx),
                images: (1...11).map {
                    WindowsImage(index: $0, name: "Windows 11 Edition \($0)", architecture: .x64, build: 26100, totalBytes: 0)
                },
                hasBootLoader: true
            ))
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
            ("one ISO chosen", try viewModel(isoCount: 1)),
            // The list scrolls rather than growing, so a fourth ISO must not
            // push the window taller than a first one did.
            ("three ISOs chosen", try viewModel(isoCount: 3)),
            ("six ISOs chosen", try viewModel(isoCount: 6)),
            ("analyzing", try analyzingViewModel()),
            ("merging", try viewModel(
                isoCount: 2,
                state: ProcessState(stage: .merging, progress: 30, currentFile: "Windows 11 Pro (Build 26100)")
            )),
            ("copying", try viewModel(isoCount: 1, state: ProcessState(stage: .copying, progress: 42, currentFile: "install.swm"))),
            ("stopping", try viewModel(isoCount: 1, state: ProcessState(stage: .aborting, progress: 42))),
            ("done", try viewModel(isoCount: 1, state: ProcessState(stage: .done, progress: 100))),
            ("aborted", try viewModel(isoCount: 1, state: ProcessState(stage: .aborted))),
            ("failed", try viewModel(isoCount: 1, state: .failed("The drive was disconnected."))),
            ("bad drop", try viewModel(inputError: "notes.txt is not an ISO file"))
        ]

        for (name, model) in others {
            XCTAssertEqual(fittingHeight(of: model), idle, accuracy: 0.5, "height changed in state: \(name)")
        }
    }

    private func analyzingViewModel() throws -> CrossBootViewModel {
        let model = try viewModel(isoCount: 1)
        model.isAnalyzing = true
        return model
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
