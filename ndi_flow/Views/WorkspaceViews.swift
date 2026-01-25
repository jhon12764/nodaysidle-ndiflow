//
//  WorkspaceViews.swift
//  ndi_flow
//
//  WorkspaceSidebarView and WorkspaceDetailView with cluster cards.
//  - Sidebar lists workspaces and exposes a selection binding.
//  - Detail view shows clusters for a selected DynamicWorkspace with animated transitions,
//    cluster cards and file thumbnails loaded asynchronously via ThumbnailLoader.
//
//  Target: macOS 15+, SwiftUI 6
//

import SwiftUI
import SwiftData
import AppKit

// MARK: - WorkspaceSidebarView

/// Sidebar view showing a list of `WorkspaceEntity` items.
/// Use `selection` to track the currently selected workspace id.
struct WorkspaceSidebarView: View {
    // Accept either a SwiftData Query result or a plain array of WorkspaceEntity.
    // The view itself does not modify persistence; it only displays and allows selection.
    var workspaces: [WorkspaceEntity]
    @Binding var selection: UUID?
    var onCreateWorkspace: (() -> Void)?

    init(workspaces: [WorkspaceEntity], selection: Binding<UUID?>, onCreateWorkspace: (() -> Void)? = nil) {
        self.workspaces = workspaces
        self._selection = selection
        self.onCreateWorkspace = onCreateWorkspace
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.title3.bold())
                Spacer()
                Button(action: { onCreateWorkspace?() }) {
                    Image(systemName: "plus")
                }
                .help("Create Workspace")
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List(selection: $selection) {
                if workspaces.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No workspaces yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Click + to create a workspace.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(workspaces, id: \.id) { ws in
                        WorkspaceSidebarRow(workspace: ws)
                            .tag(ws.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .background(.ultraThinMaterial)
        }
    }
}

private struct WorkspaceSidebarRow: View {
    let workspace: WorkspaceEntity
    @Environment(\.modelContext) private var modelContext
    @State private var isEditing = false
    @State private var editedName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                if isEditing {
                    TextField("Workspace Name", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($isFocused)
                        .onSubmit {
                            saveNameChange()
                        }
                        .onExitCommand {
                            cancelEditing()
                        }
                } else {
                    Text(workspace.name)
                        .font(.body)
                }
                Text("\(workspace.fileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isEditing {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            startEditing()
        }
        .contextMenu {
            Button("Rename") {
                startEditing()
            }
            Divider()
            Button("Delete", role: .destructive) {
                deleteWorkspace()
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditing {
                saveNameChange()
            }
        }
    }

    private func startEditing() {
        editedName = workspace.name
        isEditing = true
        isFocused = true
    }

    private func saveNameChange() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != workspace.name {
            workspace.name = trimmed
            try? modelContext.save()
        }
        isEditing = false
    }

    private func cancelEditing() {
        isEditing = false
        editedName = workspace.name
    }

    private func deleteWorkspace() {
        modelContext.delete(workspace)
        try? modelContext.save()
    }
}

// MARK: - WorkspaceDetailView

/// Detail view that displays clusters for a `DynamicWorkspace`.
/// The view expects a UI-driven `DynamicWorkspace` (the @Observable wrapper).
struct WorkspaceDetailView: View {
    var workspace: DynamicWorkspace
    var onFilesAdded: (([URL]) -> Void)?
    var onFileSelected: ((UUID) -> Void)?
    var onThresholdChanged: ((Float) -> Void)?
    var onRecluster: (() -> Void)?

    // Matched geometry for file movement animations
    @Namespace private var namespace

    // Grid layout
    private let gridColumns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    // State for file importing
    @State private var isImporting = false
    @State private var isProcessing = false
    @State private var showThresholdSlider = false
    @State private var localThreshold: Float = 0.75

    init(workspace: DynamicWorkspace, onFilesAdded: (([URL]) -> Void)? = nil, onFileSelected: ((UUID) -> Void)? = nil, onThresholdChanged: ((Float) -> Void)? = nil, onRecluster: (() -> Void)? = nil) {
        self.workspace = workspace
        self.onFilesAdded = onFilesAdded
        self.onFileSelected = onFileSelected
        self.onThresholdChanged = onThresholdChanged
        self.onRecluster = onRecluster
        self._localThreshold = State(initialValue: workspace.clusteringThreshold)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if workspace.clusters.isEmpty && !isProcessing {
                    emptyStateView
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(workspace.clusters, id: \.id) { cluster in
                            ClusterCardView(cluster: cluster, namespace: namespace, onFileSelected: onFileSelected)
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cluster.files.count)
                                .contextMenu {
                                    Button("View Cluster Details") {
                                        // Hook for action — navigation or sheet can be integrated by the parent
                                    }
                                    Button("Export Cluster") {
                                        // Placeholder action
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                if isProcessing {
                    HStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                        Text("Analyzing files...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
            .padding()
        }
        .background(.regularMaterial)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf, .plainText, .rtf, .image, .jpeg, .png, .heic, .tiff, .gif],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty {
                    isProcessing = true
                    onFilesAdded?(urls)
                    // Processing indicator will be cleared when clusters update
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isProcessing = false
                    }
                }
            case .failure(let error):
                print("File import error: \(error)")
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No files yet")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add files to this workspace to see them organized into clusters.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button(action: { isImporting = true }) {
                Label("Add Files", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(workspace.name)
                        .font(.title.bold())
                    Text("\(workspace.clusters.reduce(0) { $0 + $1.memberCount }) files")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                Spacer()
                Button(action: { isImporting = true }) {
                    Label("Add Files", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Button(action: {
                    onRecluster?()
                }) {
                    Label("Recluster", systemImage: "arrow.2.circlepath")
                }
                .buttonStyle(.bordered)
            }

            // Threshold slider
            HStack(spacing: 12) {
                Text("Similarity Threshold:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(localThreshold) },
                    set: { localThreshold = Float($0) }
                ), in: 0.5...0.99, step: 0.01)
                .frame(width: 200)
                Text("\(localThreshold, specifier: "%.2f")")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 40)
                Button("Apply") {
                    onThresholdChanged?(localThreshold)
                    onRecluster?()
                }
                .buttonStyle(.bordered)
                .disabled(localThreshold == workspace.clusteringThreshold)
            }

            Text("Higher = more clusters (stricter grouping), Lower = fewer clusters (looser grouping)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - ClusterCardView

private struct ClusterCardView: View {
    let cluster: FileCluster
    let namespace: Namespace.ID
    var onFileSelected: ((UUID) -> Void)?

    // Show a subset of thumbnails as a preview
    private var previewFiles: [IndexedFile] {
        Array(cluster.files.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cluster")
                    .font(.headline)
                Spacer()
                Text("\(cluster.memberCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                    .frame(height: 120)
                // Thumbnail grid
                GeometryReader { geo in
                    thumbnailGrid(in: geo.size)
                }
                .padding(6)
            }
            .frame(height: 120)

            HStack {
                Text("Coherence: \(cluster.coherenceScore, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: {
                    // Explore cluster action - open detail
                }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func thumbnailGrid(in size: CGSize) -> some View {
        // Layout thumbnails - limit to what fits in the container
        let thumbSize = CGSize(width: 48, height: 48)
        let maxThumbs = min(previewFiles.count, 5)
        HStack(spacing: 6) {
            ForEach(previewFiles.prefix(maxThumbs), id: \.id) { file in
                ThumbnailView(file: file, size: thumbSize)
                    .onTapGesture {
                        onFileSelected?(file.id)
                    }
            }
            Spacer()
        }
    }
}

// MARK: - ThumbnailView

private struct ThumbnailView: View {
    let file: IndexedFile
    let size: CGSize

    @State private var nsImage: NSImage? = nil
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .frame(width: size.width, height: size.height)

            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .cornerRadius(6)
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: size.width, height: size.height)
            } else {
                // Fallback icon
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width * 0.5, height: size.height * 0.5)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            loadThumbnailIfNeeded()
        }
    }

    private func loadThumbnailIfNeeded() {
        guard nsImage == nil && !isLoading else { return }
        isLoading = true

        Task {
            defer { isLoading = false }
            do {
                // Use ThumbnailLoader actor to obtain thumbnail
                let loader = ThumbnailLoader.shared
                let img = try await loader.thumbnail(for: file.url, size: size)
                await MainActor.run {
                    self.nsImage = img
                }
            } catch {
                // ignore individual thumbnail errors; UI shows fallback icon
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
struct WorkspaceViews_Previews: PreviewProvider {
    static var sampleIndexedFile: IndexedFile {
        let v = Array(repeating: Float(0.01), count: SemanticEmbedding.dimension)
        let emb = SemanticEmbedding(vector: v, keywords: ["example"], labels: [], analysisType: .document, confidence: 0.9, analysisTimestamp: Date())
        let tmpURL = URL(fileURLWithPath: "/tmp/example.txt")
        return IndexedFile(url: tmpURL, fileName: "example.txt", fileType: "public.text", fileSize: 1234, createdDate: Date(), modifiedDate: Date(), embedding: emb, status: .indexed)
    }

    static var sampleCluster: FileCluster {
        var c = FileCluster(files: [sampleIndexedFile, sampleIndexedFile, sampleIndexedFile])
        _ = c.recomputeCentroid()
        return c
    }

    static var sampleDynamicWorkspace: DynamicWorkspace {
        DynamicWorkspace(name: "Sample Workspace", clusteringThreshold: 0.75, clusters: [sampleCluster, sampleCluster])
    }

    static var previews: some View {
        Group {
            WorkspaceDetailView(workspace: sampleDynamicWorkspace)
                .frame(width: 1000, height: 700)

            // Sidebar preview: synthesize WorkspaceEntity-like objects using in-memory persistence if available.
            // For preview convenience, create fake WorkspaceEntity wrappers when SwiftData preview context is not available.
            // Here we fall back to rendering with placeholder environment.
            VStack {
                Text("Sidebar Preview")
                WorkspaceSidebarView(workspaces: [], selection: .constant(nil))
                    .frame(width: 300)
            }
            .frame(width: 320, height: 600)
        }
    }
}
#endif
