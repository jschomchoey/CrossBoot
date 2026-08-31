import Foundation

// How fast a transfer is running, measured well enough to put on screen.
//
// URLSession reports a 18 GB download tens of thousands of times, and the rate
// between two of those reports swings wildly. Samples are therefore collected
// over a window and averaged into the figure already being shown, so what the
// status line says moves with the transfer rather than with each packet.
struct TransferRate {
    // The shortest stretch a figure may be measured over.
    private static let window: TimeInterval = 1
    // How far a new measurement pulls the figure already on screen.
    private static let smoothing = 0.35

    private var markBytes: Int64 = 0
    private var markTime: TimeInterval?

    private(set) var bytesPerSecond: Double?

    // `totalBytes` is the running total the transfer has written, and `time` a
    // monotonic clock reading.
    mutating func record(_ totalBytes: Int64, at time: TimeInterval) {
        // A transfer that restarts counts from further back than the mark, and
        // measuring across that would report a negative rate.
        guard let mark = markTime, totalBytes >= markBytes, time > mark else {
            markBytes = totalBytes
            markTime = time
            return
        }

        let elapsed = time - mark
        guard elapsed >= Self.window else { return }

        let measured = Double(totalBytes - markBytes) / elapsed
        markBytes = totalBytes
        markTime = time

        // The first figure is taken as measured; later ones move towards it.
        bytesPerSecond = bytesPerSecond.map { $0 + (measured - $0) * Self.smoothing } ?? measured
    }

    // What the status line says, or nil until a full window has been measured.
    var formatted: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }

        return "\(Int64(bytesPerSecond).formattedSize)/s"
    }
}
