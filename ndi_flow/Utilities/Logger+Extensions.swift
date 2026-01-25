import Foundation
import OSLog

extension Logger {
    /// Using the bundle identifier for the subsystem
    private static let subsystem = "com.ndiflow.app"

    /// Categories for different modules of the application
    static let indexing = Logger(subsystem: subsystem, category: "Indexing")
    static let ml = Logger(subsystem: subsystem, category: "ML")
    static let fileMonitor = Logger(subsystem: subsystem, category: "FileMonitor")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
}

/// Signpost helper for performance tracing
extension OSSignposter {
    private static let subsystem = "com.ndiflow.app"

    static let mlSignposter = OSSignposter(subsystem: subsystem, category: "MLTracing")
    static let indexingSignposter = OSSignposter(subsystem: subsystem, category: "IndexingTracing")
}
