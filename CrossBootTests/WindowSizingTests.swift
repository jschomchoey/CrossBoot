import XCTest
import SwiftUI
import AppKit
@testable import CrossBoot

// The window is one fixed size. Each mode has to report the same height in every
// state it can reach, whatever is showing in the status line, because a
// scroll-disabled form just clips whatever does not fit - and the window itself
// has to be the height those pages ask for, or it ends in a band of empty
// window above the action bar.
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

    // A window taller than both pages is what leaves the empty band; a window
    // shorter than either clips it.
    func testTheWindowIsTheHeightOfTheTallerPage() throws {
        let windows = fittingHeight(of: try viewModel())
        let macOS = fittingHeight(of: try macOSViewModel(versions: 3))

        XCTAssertEqual(
            max(windows, macOS), WindowLayout.height, accuracy: 1,
            "the pages want \(windows)pt and \(macOS)pt but the window is fixed at \(WindowLayout.height)pt"
        )
    }

    // The window is shared, so a page may ask for less than it - the two modes
    // hold different controls - but not for much less, and never for more.
    @discardableResult
    private func assertOneHeight(
        named mode: String,
        across states: [(String, CrossBootViewModel)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGFloat {
        let first = try XCTUnwrap(states.first, file: file, line: line)
        let height = fittingHeight(of: first.1)

        XCTAssertGreaterThan(height, 0, "\(mode) reported no height at all", file: file, line: line)
        XCTAssertLessThanOrEqual(
            height, WindowLayout.height,
            "\(mode) wants \(height)pt but the window is fixed at \(WindowLayout.height)pt",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            height, WindowLayout.height - Self.largestEmptyBand,
            "\(mode) wants \(height)pt, which leaves an empty band under a \(WindowLayout.height)pt window",
            file: file, line: line
        )

        for (name, model) in states.dropFirst() {
            XCTAssertEqual(
                fittingHeight(of: model), height, accuracy: 0.5,
                "\(mode) changed height in state: \(name)",
                file: file, line: line
            )
        }

        return height
    }

    // What the shorter of the two pages may leave unused before the gap above
    // the action bar reads as a layout mistake rather than as spacing.
    private static let largestEmptyBand: CGFloat = 40

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
