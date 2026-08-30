import Foundation
import os

// Shared loggers. Categories mirror the area that emits them so Console can
// filter one part of the app at a time.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.crossboot.app"

    static let disk = Logger(subsystem: subsystem, category: "disk")
    static let power = Logger(subsystem: subsystem, category: "power")
    static let process = Logger(subsystem: subsystem, category: "process")
}
