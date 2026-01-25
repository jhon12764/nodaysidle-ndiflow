//
//  WorkspaceCoordinator.swift
//  ndi_flow
//
//  Coordinates workspace state and business logic, separating concerns from ContentView.
//  Manages workspace selection, dynamic workspace mapping, file operations, and clustering.
//
//  Target: macOS 15+, Swift 6
//

import Foundation
import SwiftData
import SwiftUI
import OSLog

/// Coordinates workspace-related state and operations for the main UI.
/// Extracted from ContentView to improve separation of concerns and testability.
@MainActor
final class WorkspaceCoordinator: ObservableObject {
    // MARK: - Published State

    /// Currently selected workspace ID
    @Published var selectedWorkspaceID: UUID?

    /// Currently selected cluster ID
    @Published var selectedClusterID: UUID?

    /// Currently selected file ID
    @Published var selectedFileID: UUID?

    /// Map of WorkspaceEntity.id -> DynamicWorkspace for UI binding
    @Published private(set) var dynamicWorkspaceMap: [UUID: DynamicWorkspace] = [:]

    // MARK: - Dependencies

    private let logger = Logger.ui

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Get the DynamicWorkspace for a given workspace ID
    func dynamicWorkspace(for id: UUID) -> DynamicWorkspace? {
        dynamicWorkspaceMap[id]
    }

    /// Ensure a DynamicWorkspace exists for the given WorkspaceEntity
    func ensureDynamicWorkspace(for workspace: WorkspaceEntity) {
        guard dynamicWorkspaceMap[workspace.id] == nil else { return }
        dynamicWorkspaceMap[workspace.id] = DynamicWorkspace(
            name: workspace.name,
            clusteringThreshold: workspace.clusteringThreshold
        )
    }

    /// Sync workspace name changes from persistence to dynamic workspace
    func syncWorkspaceNames(from workspaces: [WorkspaceEntity]) {
        for ws in workspaces {
            if let dw = dynamicWorkspaceMap[ws.id], dw.name != ws.name {
                dw.name = ws.name
            }
        }
    }

    /// Update clustering threshold for a workspace
    func updateThreshold(_ threshold: Float, for workspace: WorkspaceEntity, context: ModelContext) {
        workspace.clusteringThreshold = threshold
        dynamicWorkspaceMap[workspace.id]?.clusteringThreshold = threshold
        try? context.save()
    }

    // MARK: - Workspace Creation

    /// Create a new workspace and select it
    func createWorkspace(in context: ModelContext, existingCount: Int) -> WorkspaceEntity? {
        let name = "Workspace \(existingCount + 1)"
        let newWorkspace = WorkspaceEntity(name: name)
        context.insert(newWorkspace)

        do {
            try context.save()
            selectedWorkspaceID = newWorkspace.id

            // Create corresponding DynamicWorkspace
            let dw = DynamicWorkspace(
                name: newWorkspace.name,
                clusteringThreshold: newWorkspace.clusteringThreshold
            )
            dynamicWorkspaceMap[newWorkspace.id] = dw

            logger.log("Created workspace: \(newWorkspace.name, privacy: .public)")
            return newWorkspace
        } catch {
            logger.error("Failed to save new workspace: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - File Operations

    /// Add files to a workspace by indexing them
    func addFiles(_ urls: [URL], to workspace: WorkspaceEntity) async {
        logger.log("Adding \(urls.count) files to workspace \(workspace.name, privacy: .public)")

        for url in urls {
            // Start accessing security-scoped resource
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                // Create a file system event to trigger indexing and workspace membership
                let event = FileSystemEvent(eventType: .created, filePath: url, oldPath: nil)
                _ = try await WorkspaceAggregationService.shared.updateWorkspace(workspace, withEvent: event)
                logger.log("Added file to workspace: \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to add file \(url.lastPathComponent, privacy: .public): \(String(describing: error))")
            }
        }

        // Reload clusters after adding files
        await loadClusters(for: workspace)
    }

    // MARK: - Clustering

    /// Load clusters for the given workspace and update the DynamicWorkspace
    func loadClusters(for workspace: WorkspaceEntity) async {
        // Build IndexedFile list from workspace memberships and persisted embeddings
        var indexedFiles: [IndexedFile] = []

        // Safely access memberships - copy to local array to avoid relationship issues
        let memberships = Array(workspace.memberships)

        for membership in memberships {
            guard let fileEntity = membership.file else { continue }
            guard let emb = fileEntity.embedding else { continue }

            // Safely copy embedding data to value types
            let vector = Array(emb.vector)
            let keywords = Array(emb.keywords)
            let timestamp = emb.analysisTimestamp

            let semantic = SemanticEmbedding(
                vector: vector,
                keywords: keywords,
                labels: [],
                analysisType: .document,
                confidence: 1.0,
                analysisTimestamp: timestamp
            )
            let indexed = IndexedFile(
                url: fileEntity.pathURL,
                fileName: fileEntity.fileName,
                fileType: fileEntity.fileType,
                fileSize: fileEntity.fileSize,
                createdDate: fileEntity.createdDate,
                modifiedDate: fileEntity.modifiedDate,
                embedding: semantic,
                status: .indexed
            )
            indexedFiles.append(indexed)
        }

        // Request clustering from WorkspaceAggregationService
        do {
            let clusters = try WorkspaceAggregationService.shared.clusterFiles(
                indexedFiles,
                threshold: workspace.clusteringThreshold
            )
            dynamicWorkspaceMap[workspace.id]?.updateClusters(clusters)
        } catch {
            // If clustering fails, ensure at least an empty set of clusters exists
            dynamicWorkspaceMap[workspace.id]?.updateClusters([])
            logger.debug("Clustering failed for workspace \(workspace.name, privacy: .public): \(String(describing: error))")
        }
    }

    /// Refresh clusters for the currently selected workspace
    func refreshCurrentWorkspace(from workspaces: [WorkspaceEntity]) async {
        logger.log("Refresh requested for workspaces")
        if let id = selectedWorkspaceID,
           let ws = workspaces.first(where: { $0.id == id }) {
            await loadClusters(for: ws)
        }
    }

    // MARK: - Selection Handling

    /// Handle workspace selection change
    func handleWorkspaceSelectionChange(
        newID: UUID?,
        workspaces: [WorkspaceEntity]
    ) async {
        guard let id = newID else { return }

        if dynamicWorkspaceMap[id] == nil,
           let ws = workspaces.first(where: { $0.id == id }) {
            dynamicWorkspaceMap[id] = DynamicWorkspace(
                name: ws.name,
                clusteringThreshold: ws.clusteringThreshold
            )
            await loadClusters(for: ws)
        } else if let ws = workspaces.first(where: { $0.id == id }) {
            // Sync workspace name to DynamicWorkspace
            if let dw = dynamicWorkspaceMap[id], dw.name != ws.name {
                dw.name = ws.name
            }
            // Refresh clusters for selection change
            await loadClusters(for: ws)
        }
    }

    /// Initialize selection on first appearance
    func initializeSelection(from workspaces: [WorkspaceEntity]) async {
        if selectedWorkspaceID == nil, let first = workspaces.first {
            selectedWorkspaceID = first.id
        }

        if let id = selectedWorkspaceID,
           dynamicWorkspaceMap[id] == nil,
           let ws = workspaces.first(where: { $0.id == id }) {
            dynamicWorkspaceMap[id] = DynamicWorkspace(
                name: ws.name,
                clusteringThreshold: ws.clusteringThreshold
            )
            await loadClusters(for: ws)
        }
    }

    /// Handle workspaces count change (e.g., new workspace from monitoring)
    func handleWorkspacesCountChange(workspaces: [WorkspaceEntity]) async {
        if let id = selectedWorkspaceID ?? workspaces.first?.id,
           dynamicWorkspaceMap[id] == nil,
           let ws = workspaces.first(where: { $0.id == id }) {
            dynamicWorkspaceMap[id] = DynamicWorkspace(
                name: ws.name,
                clusteringThreshold: ws.clusteringThreshold
            )
            await loadClusters(for: ws)
        }
    }
}
