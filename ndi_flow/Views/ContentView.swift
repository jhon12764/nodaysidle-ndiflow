//
//  ContentView.swift
//  ndi_flow
//
//  Main UI shell for the ndi_flow app.
//  Implements a three-column NavigationSplitView with workspace navigation.
//  Business logic is delegated to WorkspaceCoordinator.
//
//  Target: macOS 15+, SwiftUI 6, SwiftData
//

import SwiftUI
import SwiftData
import OSLog

struct ContentView: View {
    // MARK: - Environment & Queries

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\WorkspaceEntity.createdDate, order: .reverse)])
    private var workspaces: [WorkspaceEntity]

    @Query(sort: [SortDescriptor(\MonitoredFolderEntity.addedDate, order: .reverse)])
    private var monitoredFolders: [MonitoredFolderEntity]

    // MARK: - State

    @StateObject private var coordinator = WorkspaceCoordinator()
    @StateObject private var monitoringService = FolderMonitoringService.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .navigationTitle("ndi_flow")
        .toolbar { toolbarContent }
        .onAppear(perform: handleOnAppear)
        .onChange(of: coordinator.selectedWorkspaceID) { newID in
            Task {
                await coordinator.handleWorkspaceSelectionChange(newID: newID, workspaces: workspaces)
            }
        }
        .onChange(of: workspaces.map { $0.name }) { _ in
            coordinator.syncWorkspaceNames(from: workspaces)
        }
        .onChange(of: workspaces.count) { _ in
            Task {
                await coordinator.handleWorkspacesCountChange(workspaces: workspaces)
            }
        }
        .onChange(of: monitoringService.lastUpdateTime) { _ in
            handleMonitoringUpdate()
        }
    }

    // MARK: - Sidebar Column

    private var sidebarColumn: some View {
        WorkspaceSidebarView(
            workspaces: workspaces,
            selection: $coordinator.selectedWorkspaceID,
            onCreateWorkspace: handleCreateWorkspace
        )
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Content Column

    @ViewBuilder
    private var contentColumn: some View {
        if let selectedID = coordinator.selectedWorkspaceID ?? workspaces.first?.id,
           let dw = coordinator.dynamicWorkspace(for: selectedID),
           let ws = workspaces.first(where: { $0.id == selectedID }) {
            WorkspaceDetailView(
                workspace: dw,
                onFilesAdded: { urls in
                    Task { await coordinator.addFiles(urls, to: ws) }
                },
                onFileSelected: { fileID in
                    coordinator.selectedFileID = fileID
                },
                onThresholdChanged: { newThreshold in
                    coordinator.updateThreshold(newThreshold, for: ws, context: modelContext)
                },
                onRecluster: {
                    Task { await coordinator.loadClusters(for: ws) }
                }
            )
        } else if let first = workspaces.first {
            loadingView
                .onAppear { handleFirstWorkspaceAppear(first) }
        } else {
            emptyStateView
        }
    }

    // MARK: - Detail Column

    @ViewBuilder
    private var detailColumn: some View {
        if let wsID = coordinator.selectedWorkspaceID ?? workspaces.first?.id,
           let dw = coordinator.dynamicWorkspace(for: wsID),
           let fileID = coordinator.selectedFileID,
           let cluster = dw.clusterContainingFile(fileID),
           let file = cluster.files.first(where: { $0.id == fileID }) {
            fileDetailView(for: file)
        } else {
            noFileSelectedView
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 8) {
                Button(action: handleCreateWorkspace) {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Create Workspace")

                Button(action: handleRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading workspace...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
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

    private var noFileSelectedView: some View {
        VStack {
            Text("No file selected")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileDetailView(for file: IndexedFile) -> some View {
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
    }

    // MARK: - Event Handlers

    private func handleOnAppear() {
        Task {
            await coordinator.initializeSelection(from: workspaces)
        }

        // Auto-start folder monitoring on app launch
        if !monitoredFolders.isEmpty && !monitoringService.isMonitoring {
            monitoringService.startMonitoring(folders: monitoredFolders, workspaces: workspaces)
        }
    }

    private func handleFirstWorkspaceAppear(_ workspace: WorkspaceEntity) {
        if coordinator.selectedWorkspaceID == nil {
            coordinator.selectedWorkspaceID = workspace.id
        }

        let targetID = coordinator.selectedWorkspaceID ?? workspace.id
        if let ws = workspaces.first(where: { $0.id == targetID }) {
            coordinator.ensureDynamicWorkspace(for: ws)
            Task {
                await coordinator.loadClusters(for: ws)
            }
        }
    }

    private func handleCreateWorkspace() {
        if let newWorkspace = coordinator.createWorkspace(in: modelContext, existingCount: workspaces.count) {
            Task {
                await coordinator.loadClusters(for: newWorkspace)
            }
        }
    }

    private func handleRefresh() {
        Task {
            await coordinator.refreshCurrentWorkspace(from: workspaces)
        }
    }

    private func handleMonitoringUpdate() {
        if let id = coordinator.selectedWorkspaceID,
           let ws = workspaces.first(where: { $0.id == id }) {
            Task {
                await coordinator.loadClusters(for: ws)
            }
        }
    }
}

// MARK: - WorkspaceRowView

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

// MARK: - Preview

#Preview {
    ContentView()
        .modelContainer(PersistenceController.inMemory.container)
}
