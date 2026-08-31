import XCTest
import SwiftUI
import AppKit
@testable import CrossBoot

// The window is as tall as the page inside it, so each mode has to report the
// same height in every state it can reach, whatever is showing in the status
// line: a window that resized itself mid-run would move the Stop button out from
// under the pointer. The two modes may differ - switching mode is what resizes
// the window - as long as each fits the display the app has to fit.
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

    func testTheWindowsPageIsTheSameHeightInEveryState() throws {
        let idle = try viewModel()

        try assertOneHeight(
            named: "Windows mode",
            across: [
                ("nothing chosen", idle),
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
        )
    }

    func testTheMacOSPageIsTheSameHeightInEveryState() throws {
        try assertOneHeight(
            named: "macOS mode",
            across: [
                ("nothing listed", try macOSViewModel()),
                ("versions listed", try macOSViewModel(versions: 3)),
                ("many versions listed", try macOSViewModel(versions: 8)),
                ("loading", try macOSViewModel(loading: true)),
                ("reloading with versions listed", try macOSViewModel(versions: 3, loading: true)),
                ("showing unusable versions", try macOSViewModel(versions: 3, showsUnusable: true)),
                ("a local installer selected", try macOSViewModel(versions: 3, local: true)),
                ("downloading", try macOSViewModel(
                    versions: 3,
                    state: ProcessState(stage: .downloading, progress: 20, currentFile: "macOS Tahoe 26.6.2")
                )),
                ("waiting on the password", try macOSViewModel(
                    versions: 3,
                    state: ProcessState(stage: .authorizing, progress: 55)
                )),
                ("writing", try macOSViewModel(
                    versions: 3,
                    state: ProcessState(stage: .writingInstaller, progress: 80)
                )),
                ("failed", try macOSViewModel(versions: 3, state: .failed("The drive was disconnected.")))
            ]
        )
    }

    private func assertOneHeight(
        named mode: String,
        across states: [(String, CrossBootViewModel)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let first = try XCTUnwrap(states.first, file: file, line: line)
        let height = fittingHeight(of: first.1)

        XCTAssertGreaterThan(height, 0, "\(mode) reported no height at all", file: file, line: line)
        XCTAssertLessThanOrEqual(
            height, WindowLayout.maximumHeight,
            "\(mode) wants \(height)pt, more than the \(WindowLayout.maximumHeight)pt a window may take",
            file: file, line: line
        )

        for (name, model) in states.dropFirst() {
            XCTAssertEqual(
                fittingHeight(of: model), height, accuracy: 0.5,
                "\(mode) changed height in state: \(name)",
                file: file, line: line
            )
        }
    }

    private func macOSViewModel(
        versions: Int = 0,
        loading: Bool = false,
        showsUnusable: Bool = false,
        local: Bool = false,
        state: ProcessState = ProcessState()
    ) throws -> CrossBootViewModel {
        let model = try viewModel()
        model.mediaKind = .macOS
        model.isLoadingVersions = loading
        model.showsUnusableVersions = showsUnusable

        // An installer the user pointed at is the one entry the section menu
        // offers to remove, and it summarizes without a download.
        if local {
            model.localInstallers = [
                MacOSInstaller(
                    name: "macOS Tahoe",
                    version: MacOSVersion([26, 6, 2]),
                    build: "25G83",
                    sizeBytes: 18_384_624_402,
                    minimumHostVersion: nil,
                    origin: .application(URL(fileURLWithPath: "/Applications/Install macOS Tahoe.app"))
                )
            ]
        }

        model.remoteInstallers = (0..<versions).map { index in
            MacOSInstaller(
                name: "macOS Release \(index)",
                version: MacOSVersion([26 - index, 6, 2]),
                build: "25G8\(index)",
                sizeBytes: 18_384_624_402,
                minimumHostVersion: nil,
                origin: .catalog(
                    productID: "140-9358\(index)",
                    packageURL: URL(fileURLWithPath: "/tmp/InstallAssistant.pkg")
                )
            )
        }
        model.refreshVersionList()

        model.processState = state
        return model
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
