import Foundation

// Reads the privileged step's progress out of what it writes.
//
// Neither createinstallmedia nor diskutil offers a machine-readable channel, and
// createinstallmedia writes its percentages as dots on one unterminated line, so
// the whole log is re-read each time rather than waiting for a line to end.
enum CreateInstallMediaOutput {
    enum Phase: Equatable {
        case preparing
        case erasing
        case writing
        case finished
        case stopped
    }

    struct Report: Equatable {
        let phase: Phase
        // How far through that phase, 0 to 1. Only writing reports one: the
        // others are a step of the run rather than a stretch of it.
        let fraction: Double
    }

    // The markers the privileged script prints between steps.
    private static let markers: [(text: String, phase: Phase)] = [
        ("CrossBoot: preparing", .preparing),
        ("CrossBoot: erasing", .erasing),
        ("CrossBoot: writing", .writing),
        ("CrossBoot: finished", .finished),
        ("CrossBoot: stopped", .stopped)
    ]

    // `expecting` is how many bytes the installer will put on the drive, which
    // is what the samples the step writes are measured against.
    static func read(_ output: String, expecting expectedBytes: Int64 = 0) -> Report? {
        guard let phase = lastPhase(in: output) else { return nil }

        switch phase {
        case .preparing, .erasing, .stopped:
            return Report(phase: phase, fraction: 0)
        case .writing:
            return Report(phase: phase, fraction: writingFraction(in: output, expecting: expectedBytes))
        case .finished:
            return Report(phase: phase, fraction: 1)
        }
    }

    private static func lastPhase(in output: String) -> Phase? {
        markers
            .compactMap { marker in output.range(of: marker.text, options: .backwards).map { ($0.lowerBound, marker.phase) } }
            .max { $0.0 < $1.0 }?
            .1
    }

    // createinstallmedia erases the volume it was handed, copies the installer
    // onto it, then makes it bootable. Copying is nearly all of the time - and on
    // current releases it is also silent, which is why the step samples the drive
    // itself and why those samples are read first.
    private static func writingFraction(in output: String, expecting expectedBytes: Int64) -> Double {
        guard let start = output.range(of: "CrossBoot: writing", options: .backwards) else { return 0 }

        let tail = String(output[start.upperBound...])

        // The only line that means the drive is finished with. Every other line
        // the tool prints is written before it stops writing to the drive.
        if tail.contains("Install media now available") { return 1 }

        // Whichever source has got furthest is the one to believe. They measure
        // the same copy by different means, any of them can stall - a counter
        // the drive resets when it is re-partitioned, a release that prints no
        // percentage at all - so the bar follows the one that still knows
        // something rather than the first one asked.
        var fraction = 0.0

        // What has actually reached the drive, which is the only figure that
        // moves while createinstallmedia copies in silence. Held short of the
        // end: it stops growing before the tool is finished with the drive.
        if expectedBytes > 0, let copied = lastCopiedBytes(in: tail) {
            fraction = max(fraction, min(Double(copied) / Double(expectedBytes), 0.95))
        }

        // Releases up to Monterey printed a percentage for the copy.
        if let copying = tail.range(of: "Copying to disk:", options: .backwards) {
            fraction = max(fraction, 0.1 + lastPercent(in: String(tail[copying.upperBound...])) / 100 * 0.85)
        }

        // Current releases print these three and then copy for half an hour
        // without printing anything else, so each of them says the copy has
        // begun and nothing more - "Making disk bootable" least of all, which
        // on those releases is written before the drive is written. Reading it
        // as the end of the copy is what held the bar at 97% for the whole of
        // it. Where a release prints a figure, that figure is already above
        // this and wins.
        if copyStarted.contains(where: tail.contains) {
            fraction = max(fraction, 0.15)
        }

        // The tool erases the volume again itself before it copies anything.
        if let erasing = tail.range(of: "Erasing disk:", options: .backwards) {
            fraction = max(fraction, lastPercent(in: String(tail[erasing.upperBound...])) / 100 * 0.1)
        }

        return fraction
    }

    // Lines the tool prints on the way into the copy, in the order it prints
    // them. None of them is a measure of one.
    private static let copyStarted = [
        "Copying essential files",
        "Copying the macOS RecoveryOS",
        "Making disk bootable"
    ]

    // "CrossBoot: copied 1234" - the kilobytes the step last saw on the drive.
    static func lastCopiedBytes(in text: String) -> Int64? {
        guard let marker = text.range(of: "CrossBoot: copied ", options: .backwards) else { return nil }

        let digits = text[marker.upperBound...].prefix { $0.isNumber }

        return Int64(digits).map { $0 * 1024 }
    }

    // "0%... 10%... 20%" - the figure that counts is the last one written.
    static func lastPercent(in text: String) -> Double {
        var digits = ""
        var latest: Double = 0

        for character in text {
            if character.isNumber {
                digits.append(character)
            } else {
                if character == "%", let value = Double(digits), value <= 100 {
                    latest = value
                }
                digits = ""
            }
        }

        return latest
    }
}
