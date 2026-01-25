import Foundation
import CoreServices
import OSLog

/// FSEvents-based monitor wrapper that exposes file system events as an `AsyncStream<FileSystemEvent>`.
/// - Features:
///   - Uses `kFSEventStreamCreateFlagFileEvents` to get per-file events.
///   - Bridges native C callback into Swift using a context pointer.
///   - Debounces rapid events into a single consolidated emission window (default 500ms).
///   - Emits structured `FileSystemEvent` values (see Services/FileSystemEvent.swift).
final class FSEventsMonitor: @unchecked Sendable {
    // Public configuration
    private let debounceInterval: TimeInterval

    // Private FSEvents objects
    private var stream: FSEventStreamRef?
    private let monitorQueue: DispatchQueue

    // Pending events collected during debounce window
    private var pendingEvents: [URL: FileEventType] = [:]
    private var debounceWorkItem: DispatchWorkItem?

    // Active AsyncStream continuation (set when startMonitoring is called)
    private var continuation: AsyncStream<FileSystemEvent>.Continuation?

    // Logger
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ndiflow.app", category: "FileMonitor")

    // Serial queue used to synchronize access to pendingEvents and the stream lifecycle
    private let serialAccessQueue = DispatchQueue(label: "com.ndiflow.fsevents.access", qos: .utility)

    init(debounceInterval: TimeInterval = 0.5, queueLabel: String = "com.ndiflow.fsevents") {
        self.debounceInterval = debounceInterval
        self.monitorQueue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    deinit {
        stopMonitoring()
    }

    /// Start monitoring the provided directories. Returns an `AsyncStream` of `FileSystemEvent`.
    /// - Important: The returned stream completes when `stopMonitoring()` is called or the monitor is deinitialized.
    /// - Parameter directories: URLs of directories to monitor. Non-existent paths will be ignored (logged).
    func startMonitoring(directories: [URL]) -> AsyncStream<FileSystemEvent> {
        // If already started, return a new stream that will be closed immediately to avoid surprising reuse.
        if continuation != nil {
            logger.warning("startMonitoring called while monitor already active. Returning a fresh ended stream.")
            return AsyncStream { $0.finish() }
        }

        // Validate and normalize directories
        let validDirs = directories.compactMap { url -> String? in
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                return url.path
            } else {
                logger.warning("Ignoring non-existent monitor path: \(url.path, privacy: .public)")
                return nil
            }
        }

        let stream = AsyncStream<FileSystemEvent> { [weak self] cont in
            guard let self = self else {
                cont.finish()
                return
            }

            self.serialAccessQueue.sync {
                self.continuation = cont
            }

            // If there are no valid directories we finish the stream immediately
            guard !validDirs.isEmpty else {
                logger.debug("No valid directories to monitor; finishing stream.")
                self.serialAccessQueue.sync {
                    self.continuation?.finish()
                    self.continuation = nil
                }
                return
            }

            // Prepare FSEventStream context with self as info pointer
            var context = FSEventStreamContext(
                version: 0,
                info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            // Create CFArray of paths
            let pathsArray = validDirs as CFArray

            // Create stream with file-level events
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            let latency = debounceInterval

            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                FSEventsMonitor.eventCallback,
                &context,
                pathsArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                logger.fault("Failed to create FSEventStream")
                self.serialAccessQueue.sync {
                    self.continuation?.finish()
                    self.continuation = nil
                }
                return
            }

            // Assign and configure
            self.serialAccessQueue.sync {
                self.stream = created
            }

            // Prefer dispatch queue API for callbacks
            FSEventStreamSetDispatchQueue(created, self.monitorQueue)
            if !FSEventStreamStart(created) {
                logger.fault("Failed to start FSEventStream")
                self.serialAccessQueue.sync {
                    if let s = self.stream {
                        FSEventStreamStop(s)
                        FSEventStreamInvalidate(s)
                        FSEventStreamRelease(s)
                        self.stream = nil
                    }
                    self.continuation?.finish()
                    self.continuation = nil
                }
            } else {
                logger.log("FSEventStream started for paths: \(validDirs.joined(separator: ", "), privacy: .public)")
            }

            // When the AsyncStream is terminated externally, ensure we stop the underlying stream.
            cont.onTermination = { @Sendable _ in
                // Use serial queue to synchronize cleanup
                self.serialAccessQueue.sync {
                    self._stopStreamIfNeeded()
                    self.continuation = nil
                }
            }
        }

        return stream
    }

    /// Stop monitoring and finish the active stream (if any).
    func stopMonitoring() {
        serialAccessQueue.sync {
            // Finish stream continuation first so consumers know we're ending
            continuation?.finish()
            continuation = nil

            _stopStreamIfNeeded()
            // Clear any pending events
            pendingEvents.removeAll()
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
        }
    }

    // MARK: - Private helpers

    /// Shared cleanup used in multiple places, must be called on `serialAccessQueue`.
    private func _stopStreamIfNeeded() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            logger.log("FSEventStream stopped and released.")
        }
    }

    /// Handle raw callback events from FSEvents. This is invoked on `monitorQueue`.
    private func handleRawEvents(numEvents: Int,
                                 eventPathsPointer: UnsafeMutableRawPointer?,
                                 eventFlags: UnsafePointer<FSEventStreamEventFlags>?,
                                 eventIds: UnsafePointer<FSEventStreamEventId>?) {
        guard let eventPathsPointer = eventPathsPointer else { return }

        // eventPathsPointer is a C array of const char* (char**)
        let paths = eventPathsPointer.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let flagsBuffer = eventFlags

        // Iterate and map each path -> eventType, updating pendingEvents
        for i in 0..<numEvents {
            guard let cPath = paths[i] else { continue }
            let rawPath = String(cString: cPath)
            let url = URL(fileURLWithPath: rawPath)

            var eventType: FileEventType = .modified
            if let flags = flagsBuffer?[i] {
                // Map FSEvent flags to FileEventType (best-effort)
                let f = flags
                if (f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0 {
                    eventType = .deleted
                } else if (f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0 {
                    eventType = .renamed
                } else if (f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0 {
                    eventType = .created
                } else if (f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0 {
                    eventType = .modified
                } else {
                    eventType = .modified
                }
            }

            // Synchronize update to pending events
            serialAccessQueue.async {
                // If there is an existing event for the same path, keep the most 'significant' event.
                // Ordering precedence: deleted/renamed > created > modified
                if let existing = self.pendingEvents[url] {
                    let resolved = FSEventsMonitor.resolve(preferred: eventType, existing: existing)
                    self.pendingEvents[url] = resolved
                } else {
                    self.pendingEvents[url] = eventType
                }
                self.scheduleDebounceFlushLocked()
            }
        }
    }

    /// Determine which event type should win when multiple events for the same path are coalesced.
    private static func resolve(preferred: FileEventType, existing: FileEventType) -> FileEventType {
        // ranking: deleted/renamed (highest) > created > modified
        func rank(_ t: FileEventType) -> Int {
            switch t {
            case .deleted: return 3
            case .renamed: return 3
            case .created: return 2
            case .modified: return 1
            }
        }
        return rank(preferred) >= rank(existing) ? preferred : existing
    }

    /// Schedule (or reschedule) a debounce flush. Must be called on `serialAccessQueue` or in protected context.
    private func scheduleDebounceFlushLocked() {
        // Cancel previous work item
        debounceWorkItem?.cancel()

        // Create a new work item that will flush pending events after debounceInterval
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.flushPendingEvents()
        }
        debounceWorkItem = work

        // Schedule on monitorQueue (the same queue FSEvents callbacks run on)
        monitorQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Flush pending events into the AsyncStream. Called on monitorQueue via the debounce work item.
    private func flushPendingEvents() {
        // Snapshot and clear pending events atomically
        var snapshot: [URL: FileEventType] = [:]
        serialAccessQueue.sync {
            snapshot = pendingEvents
            pendingEvents.removeAll()
            debounceWorkItem = nil
        }

        guard !snapshot.isEmpty else { return }

        // Emit consolidated FileSystemEvent for each entry
        for (url, type) in snapshot {
            let event = FileSystemEvent(eventType: type, filePath: url, oldPath: nil, timestamp: Date())
            // Yield to continuation on the serialAccessQueue to keep ordering consistent
            serialAccessQueue.async {
                if let cont = self.continuation {
                    cont.yield(event)
                } else {
                    self.logger.debug("No active continuation to yield event: \(event.summary, privacy: .public)")
                }
            }
        }
    }
}

// MARK: - FSEvent callback trampoline

private extension FSEventsMonitor {
    /// Static C-compatible callback that forwards events to the instance.
    static let eventCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
        guard let info = clientCallBackInfo else { return }
        // Reconstruct `self` from the context pointer
        let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()
        monitor.handleRawEvents(numEvents: numEvents, eventPathsPointer: eventPaths, eventFlags: eventFlags, eventIds: eventIds)
    }
}
