//
//  SettingsView.swift
//  ndi_flow
//
//  Settings panel for configuring monitored folders.
//  Allows adding/removing folders and associating them with workspaces.
//
//  Target: macOS 15+, SwiftUI 6, SwiftData
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\MonitoredFolderEntity.addedDate, order: .reverse)])
    private var monitoredFolders: [MonitoredFolderEntity]

    @Query(sort: [SortDescriptor(\WorkspaceEntity.createdDate, order: .reverse)])
    private var workspaces: [WorkspaceEntity]

    @StateObject private var monitoringService = FolderMonitoringService.shared

    @State private var isAddingFolder = false
    @State private var selectedWorkspaceID: UUID?
    @State private var isScanning = false
    @State private var scanProgress: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Monitored Folders")
                        .font(.title2.bold())
                    Text("Files in these folders will be automatically indexed and organized.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Monitoring status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(monitoringService.isMonitoring ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(monitoringService.isMonitoring ? "Monitoring" : "Stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            if monitoredFolders.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(monitoredFolders) { folder in
                        MonitoredFolderRow(
                            folder: folder,
                            workspaces: workspaces,
                            onToggle: { toggleFolder(folder) },
                            onScan: { scanFolder(folder) },
                            onDelete: { deleteFolder(folder) }
                        )
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer with add button and controls
            HStack {
                Button(action: { isAddingFolder = true }) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if !monitoredFolders.isEmpty {
                    if monitoringService.isMonitoring {
                        Button("Stop Monitoring") {
                            monitoringService.stopMonitoring()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Start Monitoring") {
                            monitoringService.startMonitoring(folders: monitoredFolders, workspaces: workspaces)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()

            if isScanning {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(scanProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .fileImporter(
            isPresented: $isAddingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        .sheet(isPresented: .constant(selectedWorkspaceID != nil && isAddingFolder == false)) {
            if let wsID = selectedWorkspaceID {
                WorkspaceSelectionSheet(
                    workspaces: workspaces,
                    selectedID: wsID,
                    onSelect: { completeAddFolder(workspaceID: $0) },
                    onCancel: { selectedWorkspaceID = nil }
                )
            }
        }
        .onAppear {
            // Auto-start monitoring if there are enabled folders
            if !monitoredFolders.isEmpty && !monitoringService.isMonitoring {
                monitoringService.startMonitoring(folders: monitoredFolders, workspaces: workspaces)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No monitored folders")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Add a folder to start automatically organizing files.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // Temporary storage for folder being added
    @State private var pendingFolderURL: URL?

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pendingFolderURL = url

            // If no workspaces exist, create one automatically
            if workspaces.isEmpty {
                let newWS = WorkspaceEntity(name: url.lastPathComponent)
                modelContext.insert(newWS)
                try? modelContext.save()
                completeAddFolder(workspaceID: newWS.id)
            } else if workspaces.count == 1 {
                // Auto-select single workspace
                completeAddFolder(workspaceID: workspaces.first!.id)
            } else {
                // Show workspace selection
                selectedWorkspaceID = workspaces.first?.id
            }

        case .failure(let error):
            print("Folder selection error: \(error)")
        }
    }

    private func completeAddFolder(workspaceID: UUID) {
        guard let folderURL = pendingFolderURL else { return }

        // Find the workspace
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            pendingFolderURL = nil
            selectedWorkspaceID = nil
            return
        }

        // Create the monitored folder entity
        let folder = MonitoredFolderEntity(
            folderURL: folderURL,
            workspace: workspace
        )
        modelContext.insert(folder)

        do {
            try modelContext.save()

            // Restart monitoring to include the new folder
            monitoringService.restartMonitoring(folders: monitoredFolders + [folder], workspaces: workspaces)

            // Perform initial scan
            let folderName = folderURL.lastPathComponent
            isScanning = true
            scanProgress = "Scanning \(folderName)..."
            Task {
                await monitoringService.performInitialScan(of: folder)
                await MainActor.run {
                    isScanning = false
                    scanProgress = ""
                }
            }

        } catch {
            print("Failed to save monitored folder: \(error)")
        }

        pendingFolderURL = nil
        selectedWorkspaceID = nil
    }

    private func toggleFolder(_ folder: MonitoredFolderEntity) {
        folder.isEnabled.toggle()
        try? modelContext.save()
        monitoringService.restartMonitoring(folders: monitoredFolders, workspaces: workspaces)
    }

    private func scanFolder(_ folder: MonitoredFolderEntity) {
        let folderName = folder.displayName
        Task { @MainActor in
            isScanning = true
            scanProgress = "Scanning \(folderName)..."
        }
        Task {
            await monitoringService.performInitialScan(of: folder)
            await MainActor.run {
                isScanning = false
                scanProgress = ""
            }
        }
    }

    private func deleteFolder(_ folder: MonitoredFolderEntity) {
        folder.stopAccessing()
        modelContext.delete(folder)
        try? modelContext.save()
        monitoringService.restartMonitoring(folders: monitoredFolders.filter { $0.id != folder.id }, workspaces: workspaces)
    }
}

// MARK: - MonitoredFolderRow

private struct MonitoredFolderRow: View {
    let folder: MonitoredFolderEntity
    let workspaces: [WorkspaceEntity]
    let onToggle: () -> Void
    let onScan: () -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: 12) {
            // Enable toggle
            Toggle("", isOn: Binding(
                get: { folder.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            // Folder icon and info
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(folder.isEnabled ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .font(.body)
                    .foregroundStyle(folder.isEnabled ? .primary : .secondary)
                Text(folder.folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Workspace picker - use workspaceID to avoid relationship access crashes
            if let currentWSID = folder.workspaceID {
                Picker("", selection: Binding(
                    get: { currentWSID },
                    set: { newID in
                        if let newWS = workspaces.first(where: { $0.id == newID }) {
                            folder.workspace = newWS
                            folder.workspaceID = newID
                            try? modelContext.save()
                        }
                    }
                )) {
                    ForEach(workspaces) { ws in
                        Text(ws.name).tag(ws.id)
                    }
                }
                .frame(width: 140)
            }

            // Actions
            Button(action: onScan) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan folder")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove folder")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - WorkspaceSelectionSheet

private struct WorkspaceSelectionSheet: View {
    let workspaces: [WorkspaceEntity]
    @State var selectedID: UUID
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Workspace")
                .font(.headline)

            Text("Choose which workspace files from this folder should be added to.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("Workspace", selection: $selectedID) {
                ForEach(workspaces) { ws in
                    Text(ws.name).tag(ws.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Add Folder") {
                    onSelect(selectedID)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .modelContainer(PersistenceController.inMemory.container)
}
