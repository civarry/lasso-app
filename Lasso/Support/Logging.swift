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
}
