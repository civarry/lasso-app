import Foundation
import os

/// Centralized loggers. Subsystem is the bundle id; categories map to subsystems
/// of the app so Console.app filtering is easy.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.cjcarito.Lasso"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let trigger = Logger(subsystem: subsystem, category: "trigger")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let mlx = Logger(subsystem: subsystem, category: "mlx")

    /// Google Lens request lifecycle. States and timings only.
    ///
    /// Never log a URL, a query, or anything derived from the captured image here: a Lens result URL
    /// carries a search identifier for the picture the user just took, and this log is readable by
    /// any process that can run `log stream`. Timings and booleans are safe and are what makes the
    /// rate gate and the dismissal path observable at all.
    static let lens = Logger(subsystem: subsystem, category: "lens")
}

/// App memory footprint (≈ Activity Monitor's "Memory") for diagnostics.
enum MemoryReport {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / (1024 * 1024)) : 0
    }
}
