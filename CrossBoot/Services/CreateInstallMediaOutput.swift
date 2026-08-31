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
        // How far the privileged step as a whole has got, 0-100.
        let progress: Double
    }

    // The markers the privileged script prints between steps.
    private static let markers: [(text: String, phase: Phase)] = [
        ("CrossBoot: preparing", .preparing),
        ("CrossBoot: erasing", .erasing),
        ("CrossBoot: writing", .writing),
        ("CrossBoot: finished", .finished),
        ("CrossBoot: stopped", .stopped)
    ]

    // Expanding the installer is the long half of the step; the erase is seconds.
    private static let erasingStart: Double = 40
    private static let writingStart: Double = 45

    static func read(_ output: String) -> Report? {
        guard let phase = lastPhase(in: output) else { return nil }

        switch phase {
        case .preparing:
            return Report(phase: phase, progress: 0)
        case .erasing:
            return Report(phase: phase, progress: erasingStart)
        case .writing:
            let share = writingProgress(in: output) / 100
            return Report(phase: phase, progress: writingStart + share * (100 - writingStart))
        case .finished:
            return Report(phase: phase, progress: 100)
        case .stopped:
            return Report(phase: phase, progress: 0)
        }
    }

    private static func lastPhase(in output: String) -> Phase? {
        markers
            .compactMap { marker in output.range(of: marker.text, options: .backwards).map { ($0.lowerBound, marker.phase) } }
            .max { $0.0 < $1.0 }?
            .1
    }

    // createinstallmedia erases the volume it was handed, copies the installer
    // onto it, then makes it bootable. Copying is nearly all of the time.
    private static func writingProgress(in output: String) -> Double {
        guard let start = output.range(of: "CrossBoot: writing", options: .backwards) else { return 0 }

        let tail = String(output[start.upperBound...])

        if tail.contains("Install media now available") { return 100 }
        if tail.contains("Making disk bootable") { return 95 }

        if let copying = tail.range(of: "Copying to disk:", options: .backwards) {
            return 10 + lastPercent(in: String(tail[copying.upperBound...])) * 0.85
        }

        if let erasing = tail.range(of: "Erasing disk:", options: .backwards) {
            return lastPercent(in: String(tail[erasing.upperBound...])) * 0.1
        }

        return 0
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
