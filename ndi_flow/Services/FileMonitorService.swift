//
// FileMonitorService.swift
// ndi_flow
//
// Actor-based FileMonitorService that coordinates directory monitoring using FSEventsMonitor
// and a simple BookmarkManager for security-scoped bookmark persistence.
//
// Responsibilities:
// - Validate directory access (security-scoped when necessary)
// - Persist and resolve bookmarks for user-selected folders
// - Expose an AsyncStream<FileSystemEvent> via `startMonitoring(directories:)`
// - Provide lifecycle control via `stopMonitoring()`
//
// Notes:
// - This implementation provides a skeleton BookmarkManager sufficient for local-first
//   sandboxed macOS apps that need to persist user-selected folder access across launches.
// - Higher-level features (debouncing policy tuning, folder status reporting, UI bindings)
//   can be added on top of this actor in future tasks.
//
// Target: macOS 15+, Swift 6
//

import Foundation
import OSLog

// MARK: - Errors

public enum FileMonitorError: LocalizedError, Sendable {
    case invalidPath(URL)
    case directoryAccessDenied(URL)
    case bookmarkResolutionFailed(URL)
    case monitoringAlreadyActive
    case monitoringNotActive

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let url):
            return "Invalid path: \(url.path)"
        case .directoryAccessDenied(let url):
            return "Access to directory denied: \(url.path)"
        case .bookmarkResolutionFailed(let url):
            return "Failed to resolve bookmark for: \(url.path)"
        case .monitoringAlreadyActive:
            return "File monitoring is already active."
        case .monitoringNotActive:
            return "File monitoring is not active."
        }
    }
}

// MARK: - BookmarkManager (skeleton)

/// Simple bookmark manager that stores security-scoped bookmark data in UserDefaults.
/// This is intentionally lightweight and synchronous. For larger data sets or security
/// considerations, consider migrating to a more robust storage mechanism.
final class BookmarkManager {
    private let userDefaultsKey = "com.ndiflow.bookmarks"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ndiflow.app", category: "FileMonitor.Bookmark")

    /// Stored mapping: bookmarkIdentifier -> bookmarkData
    /// bookmarkIdentifier is the bookmarked URL's absoluteString
    private var stored: [String: Data] {
        get {
            guard let dict = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Data] else {
                return [:]
            }
            return dict
        }
        set {
            // Convert to [String: Any] for UserDefaults
            var boxed: [String: Any] = [:]
            for (k, v) in newValue { boxed[k] = v }
            UserDefaults.standard.set(boxed, forKey: userDefaultsKey)
            UserDefaults.standard.synchronize()
        }
    }

    init() {}

    /// Save a security-scoped bookmark for `url`.
    /// Returns true on success.
    func saveBookmark(for url: URL) -> Bool {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var current = stored
            current[url.absoluteString] = bookmarkData
            stored = current
            logger.log("Saved bookmark for \(url.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(String(describing: error))")
            return false
        }
    }

    /// Resolve a stored bookmark for the given url (by absoluteString).
    /// If the bookmark exists, returns the resolved URL (not yet started access).
    func resolveBookmark(for url: URL) -> URL? {
        guard let data = stored[url.absoluteString] else {
            return nil
        }
        var isStale: Bool = false
        do {
            let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                logger.debug("Bookmark for \(url.path, privacy: .public) was stale.")
            }
            return resolved
        } catch {
            logger.error("Failed to resolve bookmark for \(url.path, privacy: .public): \(String(describing: error))")
            return nil
        }
    }

    /// Remove a previously saved bookmark for `url`.
    func removeBookmark(for url: URL) {
        var current = stored
        current.removeValue(forKey: url.absoluteString)
        stored = current
        logger.log("Removed bookmark for \(url.path, privacy: .public)")
    }

    /// Return all stored bookmark URLs (resolved where possible). Security-scoped access is not started here.
    func allStoredBookmarkURLs() -> [URL] {
        var results: [URL] = []
        for (key, data) in stored {
            var isStale = false
            do {
                if let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                    results.append(resolved)
                } else if let u = URL(string: key) {
                    results.append(u)
                }
            }
        }
        return results
    }
}

// MARK: - FileMonitorService actor

/// Actor that exposes directory monitoring APIs and manages security-scoped access for bookmarked folders.
///
/// Public API (high-level):
/// - startMonitoring(directories:) async throws -> AsyncStream<FileSystemEvent>
/// - stopMonitoring()
///
public actor FileMonitorService {
    public static let shared = FileMonitorService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ndiflow.app", category: "FileMonitor")
    private let bookmarkManager = BookmarkManager()

    // Underlying FSEvents monitor instance (created when monitoring starts)
    private var fseventsMonitor: FSEventsMonitor?

    // Active continuation is not kept here because we return the AsyncStream produced by FSEventsMonitor directly.
    // We do, however, track security-scoped access tokens (URLs that we startedAccessing)
    // so we can stop access when monitoring stops.
    private var activeSecurityScopedURLs: [URL] = []

    // Monitoring state
    private var isMonitoring: Bool = false

    public init() {}

    deinit {
        // Note: Cannot await in deinit. Clean up synchronously what we can.
        // The FSEventsMonitor will be deallocated, stopping the stream.
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Start monitoring the supplied directories.
    /// - Parameter directories: Array of folder URLs to monitor. These may be raw file URLs or previously bookmarked URLs.
    /// - Returns: AsyncStream<FileSystemEvent> that emits file system events. Caller is responsible for iterating the stream.
    /// - Throws: FileMonitorError on validation / access failures.
    ///
    /// Behavior:
    /// - Validates that each provided directory exists (or attempts to resolve a stored bookmark).
    /// - Starts security-scoped access for bookmarked URLs as needed.
    /// - Internally creates an FSEventsMonitor and returns its AsyncStream.
    public func startMonitoring(directories: [URL]) async throws -> AsyncStream<FileSystemEvent> {
        if isMonitoring {
            throw FileMonitorError.monitoringAlreadyActive
        }

        // Resolve and validate directories:
        var validatedDirs: [URL] = []

        for dir in directories {
            // Prefer the provided URL if it exists
            if FileManager.default.fileExists(atPath: dir.path) {
                validatedDirs.append(dir)
                continue
            }

            // Try to resolve via bookmark manager if available
            if let resolved = bookmarkManager.resolveBookmark(for: dir) {
                // Attempt to start security-scoped access for resolved URL
                if resolved.startAccessingSecurityScopedResource() {
                    // Keep track to stopAccessing later
                    activeSecurityScopedURLs.append(resolved)
                    validatedDirs.append(resolved)
                } else {
                    logger.error("Failed to start security-scoped access for resolved bookmark: \(resolved.path, privacy: .public)")
                    throw FileMonitorError.directoryAccessDenied(dir)
                }
                continue
            }

            // If the URL is not present and no bookmark is available, it's an invalid path
            throw FileMonitorError.invalidPath(dir)
        }

        // If no validated directories after resolution, error out
        guard !validatedDirs.isEmpty else {
            throw FileMonitorError.invalidPath(URL(fileURLWithPath: ""))
        }

        // Create and start the FSEvents monitor
        let monitor = FSEventsMonitor(debounceInterval: 0.5, queueLabel: "com.ndiflow.fsevents.monitor")
        self.fseventsMonitor = monitor
        self.isMonitoring = true

        logger.log("Starting file monitoring for \(validatedDirs.count) directories.")

        // Start the monitor and return its stream. Note: the monitor will manage its own lifecycle
        // and will finish its AsyncStream when `stopMonitoring()` is called on this actor (we call monitor.stopMonitoring()).
        let stream = monitor.startMonitoring(directories: validatedDirs)

        return stream
    }

    /// Stop monitoring and clean up resources including stopping security-scoped access.
    public func stopMonitoring() async {
        guard isMonitoring else {
            logger.debug("stopMonitoring called but monitor was not active.")
            return
        }

        logger.log("Stopping file monitoring.")

        // Stop the underlying monitor
        fseventsMonitor?.stopMonitoring()
        fseventsMonitor = nil
        isMonitoring = false

        // Stop security-scoped access for any URLs we started
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
            logger.debug("Stopped security-scoped access for \(url.path, privacy: .public)")
        }
        activeSecurityScopedURLs.removeAll()
    }

    // MARK: - Bookmark convenience helpers

    /// Persist a bookmark for a user-selected folder and attempt to start access immediately.
    /// Returns the resolved URL if successful.
    @discardableResult
    public func addBookmarkAndStartAccess(for url: URL) async throws -> URL {
        // Validate target
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileMonitorError.invalidPath(url)
        }

        // Try to persist bookmark
        let saved = bookmarkManager.saveBookmark(for: url)
        guard saved else {
            throw FileMonitorError.bookmarkResolutionFailed(url)
        }

        // Resolve the saved bookmark and start access
        guard let resolved = bookmarkManager.resolveBookmark(for: url) else {
            throw FileMonitorError.bookmarkResolutionFailed(url)
        }

        guard resolved.startAccessingSecurityScopedResource() else {
            throw FileMonitorError.directoryAccessDenied(resolved)
        }

        // Track it so we can stop access later
        if !activeSecurityScopedURLs.contains(where: { $0 == resolved }) {
            activeSecurityScopedURLs.append(resolved)
        }

        logger.log("Added bookmark and started access for \(resolved.path, privacy: .public)")
        return resolved
    }

    /// Remove a persisted bookmark and stop access if active.
    public func removeBookmark(for url: URL) async {
        // Try to resolve what we have stored (may or may not be actively accessed)
        if let resolved = bookmarkManager.resolveBookmark(for: url) {
            // Stop access if we started it
            if let idx = activeSecurityScopedURLs.firstIndex(of: resolved) {
                resolved.stopAccessingSecurityScopedResource()
                activeSecurityScopedURLs.remove(at: idx)
                logger.log("Stopped access for removed bookmark: \(resolved.path, privacy: .public)")
            }
        }
        bookmarkManager.removeBookmark(for: url)
    }

    /// Return all stored bookmark URLs (resolved where possible). Does not start access.
    public func listBookmarks() async -> [URL] {
        bookmarkManager.allStoredBookmarkURLs()
    }
}
