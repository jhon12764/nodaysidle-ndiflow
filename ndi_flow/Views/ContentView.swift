//
//  ContentView.swift
//  ndi_flow
//
//  Basic main UI shell for the ndi_flow app.
//  Implements a three-column `NavigationSplitView` with an .ultraThinMaterial sidebar.
//  Provides lightweight placeholders for workspace list, clusters, and file detail.
//
//  Target: macOS 15+, SwiftUI 6, SwiftData
//

import SwiftUI
import SwiftData
import OSLog

struct ContentView: View {
    // SwiftData model context injected from the App entry point.
    @Environment(\.modelContext) private var modelContext

    // Query stored workspaces sorted by creation date (most recent first).
    // Uses SwiftData's @Query property wrapper to keep the UI reactive.
    @Query(sort: [SortDescriptor(\WorkspaceEntity.createdDate, order: .reverse)])
    private var workspaces: [WorkspaceEntity]

    // Query monitored folders for auto-starting monitoring on app launch
    @Query(sort: [SortDescriptor(\MonitoredFolderEntity.addedDate, order: .reverse)])
    private var monitoredFolders: [MonitoredFolderEntity]

    // Selection is the UUID of the selected workspace.
    @State private var selectedWorkspaceID: UUID?
    @State private var selectedClusterID: UUID?
    @State private var selectedFileID: UUID?
    // Map of WorkspaceEntity.id -> DynamicWorkspace for UI binding and incremental updates
    @State private var dynamicWorkspaceMap: [UUID: DynamicWorkspace] = [:]

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Observe the monitoring service to refresh when files are added from Settings
    @StateObject private var monitoringService = FolderMonitoringService.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: wire to real Workspace list
            WorkspaceSidebarView(workspaces: workspaces, selection: $selectedWorkspaceID, onCreateWorkspace: createWorkspace)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                .background(.ultraThinMaterial)
        } content: {
            // Primary content: workspace detail bound to DynamicWorkspace
            Group {
                if let selectedID = selectedWorkspaceID ?? workspaces.first?.id,
                   let dw = dynamicWorkspaceMap[selectedID],
                   let ws = workspaces.first(where: { $0.id == selectedID }) {
                    WorkspaceDetailView(
                        workspace: dw,
                        onFilesAdded: { urls in
                            Task {
                                await addFiles(urls, to: ws)
                            }
                        },
                        onFileSelected: { fileID in
                            selectedFileID = fileID
                        },
                        onThresholdChanged: { newThreshold in
                            ws.clusteringThreshold = newThreshold
                            dw.clusteringThreshold = newThreshold
                            try? modelContext.save()
                        },
                        onRecluster: {
                            Task {
                                await loadClusters(for: ws)
                            }
                        }
                    )
                } else if let first = workspaces.first {
                    // Ensure we select the first workspace and prepare its DynamicWorkspace
                    VStack {
                        ProgressView()
                        Text("Loading workspace…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        // Set selection if not set
                        if selectedWorkspaceID == nil {
                            selectedWorkspaceID = first.id
                        }
                        // Use the selected workspace (or fall back to first)
                        let targetID = selectedWorkspaceID ?? first.id
                        if let ws = workspaces.first(where: { $0.id == targetID }) {
                            if dynamicWorkspaceMap[targetID] == nil {
                                dynamicWorkspaceMap[targetID] = DynamicWorkspace(name: ws.name, clusteringThreshold: ws.clusteringThreshold)
                            }
                            Task {
                                await loadClusters(for: ws)
                            }
                        }
                    }
                } else {
                    // No workspaces at all
                    VStack {
                        Text("No workspaces")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Add a monitored folder in Settings or create a workspace to get started.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } detail: {
            // Detail column: show selected file metadata if present
            Group {
                if let wsID = selectedWorkspaceID ?? workspaces.first?.id,
                   let dw = dynamicWorkspaceMap[wsID],
                   let fileID = selectedFileID,
                   let cluster = dw.clusterContainingFile(fileID),
                   let file = cluster.files.first(where: { $0.id == fileID }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(file.fileName)
                                .font(.title)
                            Text(file.fileType)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Size: \(file.humanReadableSize)")
                                .font(.subheadline)
                            Text("Path: \(file.url.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            Text("Indexed: \(file.indexedDate.map { String(describing: $0) } ?? "n/a")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                } else {
                    VStack {
                        Text("No file selected")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("ndi_flow")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button(action: createWorkspace) {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("Create Workspace")

                    Button(action: refreshWorkspaces) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
        }
        .onAppear {
            // Initialize selection and dynamic mapping for the first workspace if present
            if selectedWorkspaceID == nil, let first = workspaces.first {
                selectedWorkspaceID = first.id
            }
            if let id = selectedWorkspaceID, dynamicWorkspaceMap[id] == nil, let ws = workspaces.first(where: { $0.id == id }) {
                dynamicWorkspaceMap[id] = DynamicWorkspace(name: ws.name, clusteringThreshold: ws.clusteringThreshold)
                Task {
                    await loadClusters(for: ws)
                }
            }

            // Auto-start folder monitoring on app launch
            if !monitoredFolders.isEmpty && !monitoringService.isMonitoring {
                monitoringService.startMonitoring(folders: monitoredFolders, workspaces: workspaces)
            }
        }
        .onChange(of: selectedWorkspaceID) { newID in
            // ensure a DynamicWorkspace exists for the selected WorkspaceEntity and load clusters
            guard let id = newID else { return }
            if dynamicWorkspaceMap[id] == nil, let ws = workspaces.first(where: { $0.id == id }) {
                dynamicWorkspaceMap[id] = DynamicWorkspace(name: ws.name, clusteringThreshold: ws.clusteringThreshold)
                Task {
                    await loadClusters(for: ws)
                }
            } else if let ws = workspaces.first(where: { $0.id == id }) {
                // Sync workspace name to DynamicWorkspace
                if let dw = dynamicWorkspaceMap[id], dw.name != ws.name {
                    dw.name = ws.name
                }
                // refresh clusters for selection change
                Task {
                    await loadClusters(for: ws)
                }
            }
        }
        .onChange(of: workspaces.map { $0.name }) { _ in
            // Sync name changes from WorkspaceEntity to DynamicWorkspace
            for ws in workspaces {
                if let dw = dynamicWorkspaceMap[ws.id], dw.name != ws.name {
                    dw.name = ws.name
                }
            }
        }
        .onChange(of: workspaces.count) { _ in
            // When workspaces change (e.g., new workspace created by monitoring),
            // ensure we have a DynamicWorkspace for the selected one
            if let id = selectedWorkspaceID ?? workspaces.first?.id,
               dynamicWorkspaceMap[id] == nil,
               let ws = workspaces.first(where: { $0.id == id }) {
                dynamicWorkspaceMap[id] = DynamicWorkspace(name: ws.name, clusteringThreshold: ws.clusteringThreshold)
                Task {
                    await loadClusters(for: ws)
                }
            }
        }
        .onChange(of: monitoringService.lastUpdateTime) { _ in
            // Files were added/updated from monitoring - refresh the current workspace
            if let id = selectedWorkspaceID, let ws = workspaces.first(where: { $0.id == id }) {
                Task {
                    await loadClusters(for: ws)
                }
            }
        }
    }

    // MARK: - Subviews

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.headline)
                Spacer()
                if workspaces.isEmpty {
                    Button("Add") {
                        createWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List(selection: $selectedWorkspaceID) {
                if workspaces.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No workspaces yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Add a monitored folder in Settings or create a workspace to get started.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(workspaces, id: \.id) { ws in
                        WorkspaceRowView(workspace: ws)
                            .tag(ws.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var contentColumn: some View {
        Group {
            if let id = selectedWorkspaceID, let dynamicWorkspace = dynamicWorkspaceMap[id] {
                WorkspaceDetailView(workspace: dynamicWorkspace)
            } else if selectedWorkspace != nil {
                VStack {
                    ProgressView()
                    Text("Loading workspace...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Text("Select a workspace")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Workspaces automatically aggregate related files based on semantic similarity.")
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var detailColumn: some View {
        Group {
            if let _ = selectedFileID {
                VStack {
                    Text("File Preview")
                        .font(.title2)
                    Text("Detailed file preview and metadata will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Text("No file selected")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Computed helpers

    private var selectedWorkspace: WorkspaceEntity? {
        guard let id = selectedWorkspaceID else { return workspaces.first }
        return workspaces.first(where: { $0.id == id })
    }

    // MARK: - Actions

    private func createWorkspace() {
        // Create and persist a new WorkspaceEntity and prepare a DynamicWorkspace for UI immediately.
        let name = "Workspace \(workspaces.count + 1)"
        let new = WorkspaceEntity(name: name)
        modelContext.insert(new)
        do {
            try modelContext.save()
            selectedWorkspaceID = new.id
            // create corresponding DynamicWorkspace and load its clusters
            let dw = DynamicWorkspace(name: new.name, clusteringThreshold: new.clusteringThreshold)
            dynamicWorkspaceMap[new.id] = dw
            Task {
                await loadClusters(for: new)
            }
            Logger.ui.log("Created workspace: \(new.name, privacy: .public)")
        } catch {
            Logger.ui.error("Failed to save new workspace: \(String(describing: error))")
        }
    }

    private func refreshWorkspaces() {
        // Refresh current selection's clusters
        Logger.ui.log("Refresh requested for workspaces")
        if let id = selectedWorkspaceID, let ws = workspaces.first(where: { $0.id == id }) {
            Task {
                await loadClusters(for: ws)
            }
        }
    }

    /// Add files to a workspace by indexing them and creating memberships
    private func addFiles(_ urls: [URL], to workspace: WorkspaceEntity) async {
        Logger.ui.log("Adding \(urls.count) files to workspace \(workspace.name, privacy: .public)")

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
                Logger.ui.log("Added file to workspace: \(url.lastPathComponent, privacy: .public)")
            } catch {
                Logger.ui.error("Failed to add file \(url.lastPathComponent, privacy: .public): \(String(describing: error))")
            }
        }

        // Reload clusters after adding files
        await loadClusters(for: workspace)
    }

    /// Load clusters for the given persisted workspace and populate the DynamicWorkspace used by the UI.
    private func loadClusters(for workspace: WorkspaceEntity) async {
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

        // Request clustering from WorkspaceAggregationService (synchronous, we're on @MainActor)
        do {
            let clusters = try WorkspaceAggregationService.shared.clusterFiles(indexedFiles, threshold: workspace.clusteringThreshold)
            dynamicWorkspaceMap[workspace.id]?.updateClusters(clusters)
        } catch {
            // If clustering fails, ensure at least an empty set of clusters exists
            dynamicWorkspaceMap[workspace.id]?.updateClusters([])
            Logger.ui.debug("Clustering failed for workspace \(workspace.name, privacy: .public): \(String(describing: error))")
        }
    }
}

// MARK: - Small row/placeholder components

private struct WorkspaceRowView: View {
    let workspace: WorkspaceEntity

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(workspace.name)
                    .font(.body)
                Text("\(workspace.fileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}



// MARK: - Previews

#Preview {
    ContentView()
        .modelContainer(PersistenceController.inMemory.container)
}
