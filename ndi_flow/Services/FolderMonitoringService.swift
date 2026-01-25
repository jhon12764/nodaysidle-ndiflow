//
//  FolderMonitoringService.swift
//  ndi_flow
//
//  Service that coordinates folder monitoring with workspace updates.
//  Watches monitored folders via FSEventsMonitor and automatically indexes
//  new/modified files into their associated workspaces.
//
//  Target: macOS 15+, Swift 6
//

import Foundation
import SwiftData
import OSLog

/// Service responsible for watching monitored folders and routing file events to workspaces.
@MainActor
final class FolderMonitoringService: ObservableObject {
    static let shared = FolderMonitoringService()

    private let logger = Logger(subsystem: "com.ndiflow.app", category: "FolderMonitoring")

    // The underlying FSEvents monitor
    private var monitor: FSEventsMonitor?

    // Active monitoring task
    private var monitoringTask: Task<Void, Never>?

    // Currently monitored folders (URL -> MonitoredFolderEntity.id)
    @Published private(set) var isMonitoring: Bool = false

    // Increments when files are added/updated - ContentView can watch this to refresh
    @Published private(set) var lastUpdateTime: Date = Date()

    // Track which folders are being monitored and their workspace associations
    private var folderWorkspaceMap: [URL: UUID] = [:] // folderURL -> workspaceID

    private init() {}

    // MARK: - Public API

    /// Start monitoring all enabled monitored folders.
    /// Call this on app launch after loading MonitoredFolderEntity from persistence.
    func startMonitoring(folders: [MonitoredFolderEntity], workspaces: [WorkspaceEntity]) {
        guard !isMonitoring else {
            logger.log("Already monitoring; call stopMonitoring first to restart.")
            return
        }

        // Build a workspace ID lookup map using the stored workspaceID property
        // (avoids SwiftData relationship access issues that cause crashes)
        var workspaceIDLookup: [UUID: UUID] = [:] // folderID -> workspaceID
        for folder in folders {
            if folder.isEnabled, let wsID = folder.workspaceID {
                workspaceIDLookup[folder.id] = wsID
            }
        }

        // Filter to enabled folders with valid workspaces
        let enabledFolders = folders.filter { workspaceIDLookup[$0.id] != nil }

        guard !enabledFolders.isEmpty else {
            logger.log("No enabled monitored folders with workspaces; not starting monitor.")
            return
        }

        // Build URL list and workspace map
        var urls: [URL] = []
        folderWorkspaceMap.removeAll()

        for folder in enabledFolders {
            // Start security-scoped access
            _ = folder.startAccessing()

            if let resolved = folder.resolveBookmark() {
                urls.append(resolved)
                if let wsID = workspaceIDLookup[folder.id] {
                    folderWorkspaceMap[resolved] = wsID
                }
            }
        }

        guard !urls.isEmpty else {
            logger.log("No valid folder URLs to monitor after resolution.")
            return
        }

        // Create monitor and start
        monitor = FSEventsMonitor(debounceInterval: 1.0)
        let eventStream = monitor!.startMonitoring(directories: urls)

        isMonitoring = true
        logger.log("Started monitoring \(urls.count) folders")

        // Start processing events
        monitoringTask = Task { [weak self] in
            for await event in eventStream {
                guard let self = self else { break }
                await self.handleFileEvent(event)
            }
            await MainActor.run {
                self?.isMonitoring = false
            }
        }
    }

    /// Stop all folder monitoring.
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        monitor?.stopMonitoring()
        monitor = nil
        isMonitoring = false
        folderWorkspaceMap.removeAll()
        logger.log("Stopped folder monitoring")
    }

    /// Restart monitoring with updated folder list.
    func restartMonitoring(folders: [MonitoredFolderEntity], workspaces: [WorkspaceEntity]) {
        stopMonitoring()
        startMonitoring(folders: folders, workspaces: workspaces)
    }

    // MARK: - Event Handling

    private func handleFileEvent(_ event: FileSystemEvent) async {
        logger.log("File event: \(event.summary, privacy: .public)")

        // Skip directories
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: event.filePath.path, isDirectory: &isDir), isDir.boolValue {
            logger.debug("Skipping directory event: \(event.filePath.path, privacy: .public)")
            return
        }

        // Skip hidden files and system files
        let filename = event.filePath.lastPathComponent
        if filename.hasPrefix(".") || filename.hasPrefix("~") {
            logger.debug("Skipping hidden/temp file: \(filename, privacy: .public)")
            return
        }

        // Find which monitored folder this file belongs to
        guard let (folderURL, workspaceID) = findParentFolder(for: event.filePath) else {
            logger.debug("No monitored folder found for: \(event.filePath.path, privacy: .public)")
            return
        }

        // Fetch the workspace from persistence
        let context = PersistenceController.shared.mainContext
        let descriptor = FetchDescriptor<WorkspaceEntity>(predicate: #Predicate { $0.id == workspaceID })

        guard let workspace = try? context.fetch(descriptor).first else {
            logger.error("Workspace not found for ID: \(workspaceID.uuidString, privacy: .public)")
            return
        }

        // Process the event through WorkspaceAggregationService
        // Use forceAdd: true for new files to bypass similarity threshold
        let shouldForceAdd = event.eventType == .created
        do {
            _ = try await WorkspaceAggregationService.shared.updateWorkspace(workspace, withEvent: event, forceAdd: shouldForceAdd)
            logger.log("Processed file event for workspace \(workspace.name, privacy: .public): \(event.filePath.lastPathComponent, privacy: .public)")

            // Notify observers that files were updated so UI refreshes
            await MainActor.run {
                self.lastUpdateTime = Date()
            }
        } catch {
            logger.error("Failed to process file event: \(String(describing: error))")
        }
    }

    /// Find which monitored folder contains the given file path.
    private func findParentFolder(for fileURL: URL) -> (URL, UUID)? {
        let filePath = fileURL.path

        for (folderURL, workspaceID) in folderWorkspaceMap {
            let folderPath = folderURL.path
            if filePath.hasPrefix(folderPath) {
                return (folderURL, workspaceID)
            }
        }

        return nil
    }

    // MARK: - Initial Scan

    /// Perform an initial scan of a folder and index all files.
    /// Use this when adding a new monitored folder.
    func performInitialScan(of folder: MonitoredFolderEntity) async {
        // Use stored workspaceID to avoid SwiftData relationship access crashes
        guard let workspaceID = folder.workspaceID else {
            logger.log("Cannot scan folder without associated workspace ID")
            return
        }

        guard let folderURL = folder.resolveBookmark() else {
            logger.error("Cannot resolve folder URL for scanning")
            return
        }

        _ = folder.startAccessing()
        defer { folder.stopAccessing() }

        logger.log("Starting initial scan of: \(folderURL.path, privacy: .public)")

        // Fetch the workspace fresh from the context for each operation
        let context = PersistenceController.shared.mainContext
        let descriptor = FetchDescriptor<WorkspaceEntity>(predicate: #Predicate { $0.id == workspaceID })

        guard let workspace = try? context.fetch(descriptor).first else {
            logger.error("Workspace not found for ID: \(workspaceID.uuidString, privacy: .public)")
            return
        }

        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var fileCount = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            // Skip directories
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            // Create a file event and process it - forceAdd bypasses similarity check during initial scan
            let event = FileSystemEvent(eventType: .created, filePath: fileURL)

            do {
                _ = try await WorkspaceAggregationService.shared.updateWorkspace(workspace, withEvent: event, forceAdd: true)
                fileCount += 1
            } catch {
                logger.error("Failed to index file during scan: \(fileURL.lastPathComponent, privacy: .public) - \(String(describing: error))")
            }
        }

        logger.log("Initial scan complete: indexed \(fileCount) files from \(folderURL.path, privacy: .public)")

        // Notify observers that files were updated
        if fileCount > 0 {
            await MainActor.run {
                self.lastUpdateTime = Date()
            }
        }
    }
}
