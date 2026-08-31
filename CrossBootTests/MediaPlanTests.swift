import XCTest
@testable import CrossBoot

// The plan decides what boots. Picking the wrong base ISO produces media that
// either fails Secure Boot or refuses to install the newer image, and neither
// shows up until the drive is already in a machine.
final class MediaPlanTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("media-plan-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeISO(
        _ name: String,
        build: Int,
        editions: [String] = ["Home", "Pro"],
        architecture: WindowsArchitecture? = .x64,
        installImage: String? = "sources/install.wim",
        imageBytes: Int64 = 5_000_000_000,
        compression: WimCompression = .lzx,
        hasBootLoader: Bool = true
    ) throws -> ISOFile {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: 1).write(to: url)

        return try ISOFile(
            url: url,
            installImage: installImage.map {
                InstallImage(relativePath: $0, sizeBytes: imageBytes, compression: compression)
            },
            images: editions.enumerated().map { offset, edition in
                WindowsImage(
                    index: offset + 1,
                    name: "Windows \(edition)",
                    architecture: architecture,
                    build: build,
                    totalBytes: 10_000_000_000
                )
            },
            hasBootLoader: hasBootLoader
        )
    }

    // MARK: - Single source

    func testOneISOIsCopiedRatherThanMerged() throws {
        let iso = try makeISO("Win11.iso", build: 26100)
        let plan = try InstallMediaPlan.make(from: [iso])

        guard case .single = plan.mode else {
            return XCTFail("a lone ISO should not be rewritten")
        }

        XCTAssertEqual(plan.sources, [iso])
        XCTAssertTrue(plan.plannedImages.isEmpty)
    }

    // An ISO with no install.wim is still perfectly bootable on its own, which
    // is how CrossBoot has always treated it.
    func testALoneISOWithoutAnInstallImageIsStillAllowed() throws {
        let iso = try makeISO("WinPE.iso", build: 0, editions: [], installImage: nil)

        XCTAssertNoThrow(try InstallMediaPlan.make(from: [iso]))
    }

    func testNoSourcesIsRejected() {
        XCTAssertThrowsError(try InstallMediaPlan.make(from: []))
    }

    // MARK: - Choosing the base

    // Secure Boot survives only because every boot binary is copied unmodified
    // from one ISO, and that ISO has to be the newest: a Windows 10 setup
    // cannot deploy a Windows 11 image, but the reverse works.
    func testTheNewestISOSuppliesTheBootFiles() throws {
        let win10 = try makeISO("Win10.iso", build: 19045)
        let win11 = try makeISO("Win11.iso", build: 26100)

        let plan = try InstallMediaPlan.make(from: [win10, win11])

        XCTAssertEqual(plan.base, win11)
    }

    func testAnISOWithoutABootLoaderIsNeverTheBase() throws {
        let newestNoBoot = try makeISO("Win11-noboot.iso", build: 26100, hasBootLoader: false)
        let older = try makeISO("Win10.iso", build: 19045)

        let plan = try InstallMediaPlan.make(from: [newestNoBoot, older])

        XCTAssertEqual(plan.base, older)
    }

    func testNoBootLoaderAnywhereIsRejected() throws {
        let first = try makeISO("a.iso", build: 26100, hasBootLoader: false)
        let second = try makeISO("b.iso", build: 19045, hasBootLoader: false)

        XCTAssertThrowsError(try InstallMediaPlan.make(from: [first, second])) { error in
            XCTAssertEqual(error as? MediaPlanError, .noBootLoader)
        }
    }

    // The base is what supplies boot.wim, so it must be mounted during the run
    // even when an earlier ISO already contributed every edition it holds.
    func testTheBaseIsAlwaysMountedEvenWhenItContributesNoImages() throws {
        let noBoot = try makeISO("Win11-noboot.iso", build: 26100, hasBootLoader: false)
        let bootable = try makeISO("Win11-bootable.iso", build: 26100)

        let plan = try InstallMediaPlan.make(from: [noBoot, bootable])

        XCTAssertEqual(plan.base, bootable)
        XCTAssertTrue(plan.sources.contains(bootable))
    }

    // MARK: - Image selection

    func testEveryEditionFromEveryISOReachesTheMenu() throws {
        let win10 = try makeISO("Win10.iso", build: 19045, editions: ["Home", "Pro", "Education"])
        let win11 = try makeISO("Win11.iso", build: 26100, editions: ["Home", "Pro"])

        let plan = try InstallMediaPlan.make(from: [win10, win11])

        XCTAssertEqual(plan.plannedImages.count, 5)
        // The newest build leads, so it is what setup preselects.
        XCTAssertEqual(plan.plannedImages.first?.name, "Windows Home (Build 26100)")
    }

    // Two ISOs of the same release carry the same editions; listing each twice
    // would both waste the drive and make the menu meaningless.
    func testIdenticalEditionsFromTheSameBuildAreListedOnce() throws {
        let home = try makeISO("Win11-home.iso", build: 26100, editions: ["Home", "Pro"])
        let pro = try makeISO("Win11-pro.iso", build: 26100, editions: ["Pro", "Enterprise"])

        let plan = try InstallMediaPlan.make(from: [home, pro])

        XCTAssertEqual(plan.plannedImages.map(\.name).sorted(), [
            "Windows Enterprise (Build 26100)",
            "Windows Home (Build 26100)",
            "Windows Pro (Build 26100)"
        ])
    }

    // The same edition name across two releases is the normal case, so the
    // build is what tells them apart in setup.
    func testSameEditionFromDifferentBuildsStaysDistinguishable() throws {
        let win10 = try makeISO("Win10.iso", build: 19045, editions: ["Pro"])
        let win11 = try makeISO("Win11.iso", build: 26100, editions: ["Pro"])

        let plan = try InstallMediaPlan.make(from: [win10, win11])

        XCTAssertEqual(plan.plannedImages.map(\.name), [
            "Windows Pro (Build 26100)",
            "Windows Pro (Build 19045)"
        ])
    }

    // MARK: - Refusals

    func testMixedArchitecturesAreRefused() throws {
        let intel = try makeISO("Win11-x64.iso", build: 26100, architecture: .x64)
        let arm = try makeISO("Win11-arm64.iso", build: 26100, architecture: .arm64)

        XCTAssertThrowsError(try InstallMediaPlan.make(from: [intel, arm])) { error in
            guard case .mixedArchitectures = error as? MediaPlanError else {
                return XCTFail("expected an architecture refusal, got \(error)")
            }
        }
    }

    func testAnISOWithoutAnInstallImageCannotBeCombined() throws {
        let windows = try makeISO("Win11.iso", build: 26100)
        let other = try makeISO("Ubuntu.iso", build: 0, editions: [], installImage: nil)

        XCTAssertThrowsError(try InstallMediaPlan.make(from: [windows, other])) { error in
            XCTAssertEqual(error as? MediaPlanError, .noInstallImage("Ubuntu.iso"))
        }
    }

    // MARK: - Compression

    // The merged image is all but always over the FAT32 limit, so it has to be
    // splittable - and wimlib refuses to split a WIM holding solid resources.
    // Choosing solid here fails the run at the split, hours in.
    func testMergedMediaIsNeverSolid() throws {
        let win10 = try makeISO("Win10.iso", build: 19045, compression: .lzms)
        let win11 = try makeISO("Win11.iso", build: 26100, compression: .lzms)

        let plan = try InstallMediaPlan.make(from: [win10, win11])

        guard case .merged(_, _, let compression) = plan.mode else {
            return XCTFail("two ISOs should merge")
        }

        XCTAssertTrue(compression.isSplittable)
        XCTAssertEqual(compression, .lzx)
    }

    // Matching the format the sources already use lets wimlib copy their data
    // across instead of recompressing it, which is minutes per edition.
    func testTheMergedFormatFollowsTheSourcesThatHoldMostOfTheBytes() throws {
        let mostly = try makeISO("Win11.iso", build: 26100, imageBytes: 6_000_000_000, compression: .xpress)
        let rest = try makeISO("Win10.iso", build: 19045, imageBytes: 2_000_000_000, compression: .lzx)

        guard case .merged(_, _, let compression) = try InstallMediaPlan.make(from: [mostly, rest]).mode else {
            return XCTFail("two ISOs should merge")
        }

        XCTAssertEqual(compression, .xpress)
    }

    // Nothing can be copied across from a solid source. With the splittable
    // sources in the minority the merge takes LZX, which is both what Windows
    // media ships as install.wim and the smaller file on the drive.
    func testSolidSourcesMergeIntoLZX() throws {
        let solid = try makeISO("Win11.iso", build: 26100, imageBytes: 6_000_000_000, compression: .lzms)
        let small = try makeISO("Win10.iso", build: 19045, imageBytes: 1_000_000_000, compression: .xpress)

        guard case .merged(_, _, let compression) = try InstallMediaPlan.make(from: [solid, small]).mode else {
            return XCTFail("two ISOs should merge")
        }

        XCTAssertEqual(compression, .lzx)
    }

    // MARK: - A lone ISO on FAT32

    func testAnImageThatFATCanHoldIsCopiedWhole() throws {
        let iso = try makeISO("Win11.iso", build: 26100, imageBytes: WimLibService.fat32FileLimit)

        XCTAssertEqual(InstallMediaPlan.work(for: iso), .copyWhole)
    }

    // FAT32 tops out one byte below 4 GiB, so a file of exactly 4 GiB has to be
    // split. Treating the limit as inclusive let that file through, to fail
    // mid-copy on a drive that was already erased.
    func testAnImageOfExactlyFourGiBIsSplit() throws {
        let iso = try makeISO("Win11.iso", build: 26100, imageBytes: 4 * 1024 * 1024 * 1024)

        XCTAssertEqual(InstallMediaPlan.work(for: iso), .split)
    }

    // install.esd is solid, and wimlib cannot split solid resources at all. It
    // has to be rewritten first, whatever the file happens to be named.
    func testAnOversizedSolidImageIsRewrittenBeforeItIsSplit() throws {
        let iso = try makeISO(
            "Win11.iso",
            build: 26100,
            installImage: "sources/install.esd",
            imageBytes: 5_000_000_000,
            compression: .lzms
        )

        XCTAssertEqual(InstallMediaPlan.work(for: iso), .rebuild(.lzx))
    }

    // MARK: - Sizing

    // The check runs before the drive is erased, so it has to be an upper bound:
    // deduplication between images can only make the result smaller.
    func testDriveEstimateCountsTheBaseTreePlusEveryInstallImage() throws {
        let win10 = try makeISO("Win10.iso", build: 19045, imageBytes: 4_000_000_000)
        let win11 = try makeISO("Win11.iso", build: 26100, imageBytes: 5_000_000_000)

        let plan = try InstallMediaPlan.make(from: [win10, win11])
        // Both ISO files are a single byte on disk here, so the base tree
        // contributes nothing and only the images count.
        XCTAssertEqual(plan.estimatedDriveBytes, 9_000_000_000 + 1 - 5_000_000_000)
    }

    func testMergingReservesScratchSpaceForTheSplitAsWell() throws {
        let win10 = try makeISO("Win10.iso", build: 19045, imageBytes: 4_000_000_000)
        let win11 = try makeISO("Win11.iso", build: 26100, imageBytes: 5_000_000_000)

        let plan = try InstallMediaPlan.make(from: [win10, win11])

        XCTAssertEqual(plan.estimatedTemporaryBytes, 18_000_000_000)
    }

    // A single ISO under the FAT32 limit is copied straight across, so it needs
    // no scratch space at all.
    func testASmallLoneISONeedsNoScratchSpace() throws {
        let iso = try makeISO("Win11.iso", build: 26100, imageBytes: 3_000_000_000)

        XCTAssertEqual(try InstallMediaPlan.make(from: [iso]).estimatedTemporaryBytes, 0)
    }

    // Rewriting a solid image as LZX makes it bigger, and both checks run before
    // the drive is erased. Counting the source size would pass a drive that the
    // finished media cannot fit on.
    func testASolidImageIsCountedAtWhatItWillWeighOnceRewritten() throws {
        let solid = try makeISO("Win11.iso", build: 26100, imageBytes: 5_000_000_000, compression: .lzms)
        let plan = try InstallMediaPlan.make(from: [solid])

        XCTAssertEqual(plan.estimatedDriveBytes, 7_500_000_000 + 1 - 5_000_000_000)
        // The rewrite and the parts split out of it are on disk at once.
        XCTAssertEqual(plan.estimatedTemporaryBytes, 15_000_000_000)
    }
}
