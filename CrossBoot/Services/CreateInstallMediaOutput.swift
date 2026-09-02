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

        if tail.contains("Install media now available") { return 1 }
        if tail.contains("Making disk bootable") { return 0.97 }

        // Held short of the end: what is on the drive stops growing before
        // createinstallmedia is finished with it.
        if expectedBytes > 0, let copied = lastCopiedBytes(in: tail) {
            return min(Double(copied) / Double(expectedBytes), 0.95)
        }

        // Releases up to Monterey printed a percentage for the copy.
        if let copying = tail.range(of: "Copying to disk:", options: .backwards) {
            return 0.1 + lastPercent(in: String(tail[copying.upperBound...])) / 100 * 0.85
        }

        // The tool erases the volume again itself before it copies anything.
        if let erasing = tail.range(of: "Erasing disk:", options: .backwards) {
            return lastPercent(in: String(tail[erasing.upperBound...])) / 100 * 0.1
        }

        return 0
    }

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
