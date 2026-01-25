import Foundation
import Observation
import SwiftData

/// DynamicWorkspace — an @Observable wrapper used by the UI to represent a workspace and its clusters.
/// - Conforms to `Identifiable` so it can be used in SwiftUI lists.
/// - Uses value-type `FileCluster` and `IndexedFile` types from the indexing pipeline for membership and embeddings.
@Observable
@MainActor
final class DynamicWorkspace: Identifiable {
    let id: UUID
    var name: String
    var createdDate: Date
    /// clustering threshold used by this workspace (0.0 .. 1.0)
    var clusteringThreshold: Float
    /// Clusters visible to the UI. Each `FileCluster` contains its member `IndexedFile`s and centroid.
    var clusters: [FileCluster]

    /// UI state helpers
    var isUpdating: Bool = false
    var lastUpdated: Date?

    init(
        id: UUID = UUID(),
        name: String,
        createdDate: Date = Date(),
        clusteringThreshold: Float = 0.75,
        clusters: [FileCluster] = []
    ) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.clusteringThreshold = clusteringThreshold
        self.clusters = clusters
        self.lastUpdated = Date()
    }

    // MARK: - Cluster management (UI-friendly)

    /// Replace clusters wholesale (eg. after a reclustering operation).
    func updateClusters(_ newClusters: [FileCluster]) {
        self.clusters = newClusters
        self.lastUpdated = Date()
    }

    /// Recompute centroid + coherence for each cluster in-place.
    func recomputeCentroids() {
        for idx in clusters.indices {
            _ = clusters[idx].recomputeCentroid()
        }
        self.lastUpdated = Date()
    }

    /// Add an indexed file into the best-matching cluster (if similarity >= clusteringThreshold),
    /// otherwise create a new cluster seeded with this file.
    /// - Returns: pair (wasInsertedIntoExistingCluster, indexOfCluster)
    @discardableResult
    func addFile(_ file: IndexedFile) -> (Bool, Int) {
        // if file has no embedding, create a single-file cluster
        guard let fileVec = file.embedding?.vector, !file.embedding!.isZeroVector else {
            let c = FileCluster(files: [file])
            var mutable = c
            _ = mutable.recomputeCentroid()
            clusters.append(mutable)
            lastUpdated = Date()
            return (false, clusters.count - 1)
        }

        // Find best matching cluster by comparing to each cluster's centroid
        var bestSim: Float = -1.0
        var bestIndex: Int? = nil
        for (i, cl) in clusters.enumerated() {
            if let centroid = cl.centroid {
                let sim = VectorMath.cosineSimilarity(centroid, fileVec)
                if sim > bestSim {
                    bestSim = sim
                    bestIndex = i
                }
            }
        }

        if let idx = bestIndex, bestSim >= clusteringThreshold {
            // insert into cluster
            clusters[idx].add(file)
            lastUpdated = Date()
            return (true, idx)
        } else {
            // create new cluster
            var new = FileCluster(files: [file])
            _ = new.recomputeCentroid()
            clusters.append(new)
            lastUpdated = Date()
            return (false, clusters.count - 1)
        }
    }

    /// Remove a file from all clusters by file id. Returns true if any removal occurred.
    @discardableResult
    func removeFile(withID fileID: UUID) -> Bool {
        var removedAny = false
        for i in clusters.indices.reversed() {
            let beforeCount = clusters[i].files.count
            clusters[i].remove { $0.id == fileID }
            let afterCount = clusters[i].files.count
            if afterCount == 0 {
                // drop empty clusters
                clusters.remove(at: i)
            }
            if afterCount < beforeCount {
                removedAny = true
            }
        }
        if removedAny { lastUpdated = Date() }
        return removedAny
    }

    /// Find the cluster that contains the file (if any).
    func clusterContainingFile(_ fileID: UUID) -> FileCluster? {
        return clusters.first { $0.files.contains(where: { $0.id == fileID }) }
    }

    // MARK: - Utilities & Persistence helpers

    /// Convert this DynamicWorkspace into a persisted `WorkspaceEntity` within the provided `ModelContext`.
    /// If `existing` is supplied, it will be updated; otherwise a new `WorkspaceEntity` will be created.
    /// This method performs persistence operations on the supplied context synchronously via `context.perform { }`.
    ///
    /// Note: This method expects `FileEntity` objects (and their EmbeddingEntity) to be present in the database
    /// for files referenced by the `IndexedFile`s in `clusters`. For files not present, this will create `FileEntity` and `EmbeddingEntity`.
    func persist(as existing: WorkspaceEntity? = nil, in context: ModelContext) throws -> WorkspaceEntity {
        // Use the provided context to create or update a WorkspaceEntity instance.
        // This function is synchronous from the caller's perspective and must be called from an async context
        // via `await context.perform { ... }` or similar when used outside of background contexts.
        if let ws = existing {
            // update existing
            ws.name = self.name
            ws.clusteringThreshold = self.clusteringThreshold
            ws.createdDate = self.createdDate

            // clear existing memberships and rebuild from clusters
            // Simpler approach: remove all memberships then re-add based on current clusters
            let oldMemberships = ws.memberships
            for m in oldMemberships {
                // detach membership
                // SwiftData will delete membership objects if no other references remain
            }
            ws.memberships.removeAll()

            try addMemberships(to: ws, in: context)
            try context.save()
            return ws
        } else {
            // create new WorkspaceEntity
            let ws = WorkspaceEntity(name: self.name, createdDate: self.createdDate, clusteringThreshold: self.clusteringThreshold, centroidVector: nil)
            context.insert(ws)
            try addMemberships(to: ws, in: context)
            try context.save()
            return ws
        }
    }

    /// Internal helper: for each file in clusters, ensure a FileEntity exists and create a WorkspaceMembership.
    /// This mirrors the persistence strategy used elsewhere in the app.
    private func addMemberships(to workspace: WorkspaceEntity, in context: ModelContext) throws {
        // compute centroid for workspace from cluster members if possible
        // choose a simple centroid: average of all member embeddings across clusters
        var allEmbeddings: [[Float]] = []
        for cl in clusters {
            for f in cl.files {
                if let v = f.embedding?.vector { allEmbeddings.append(v) }
            }
        }
        if !allEmbeddings.isEmpty {
            workspace.centroidVector = VectorMath.average(of: allEmbeddings)
        }

        // Iterate clusters and their files to create memberships
        for cl in clusters {
            for file in cl.files {
                // Resolve or create FileEntity for this file in the provided context
                let fileEntity = try resolveOrCreateFileEntity(for: file, in: context)
                // similarity score: compute against workspace centroid if available; otherwise use cluster coherence or 1.0
                let similarity: Float
                if let centroid = workspace.centroidVector, let emb = file.embedding?.vector {
                    similarity = VectorMath.cosineSimilarity(centroid, emb)
                } else {
                    similarity = cl.coherenceScore > 0.0 ? cl.coherenceScore : 1.0
                }
                let membership = WorkspaceMembership(workspace: workspace, file: fileEntity, similarityScore: similarity)
                context.insert(membership)
                // add to workspace relationship (relationship inverse will be set automatically)
                workspace.memberships.append(membership)
            }
        }
    }

    /// Resolve an existing `FileEntity` for `indexed` within the provided `ModelContext` or create it if missing.
    /// This function mirrors logic used in the indexing pipeline and workspace aggregation service.
    private func resolveOrCreateFileEntity(for indexed: IndexedFile, in context: ModelContext) throws -> FileEntity {
        // Query for existing FileEntity by pathURL
        let targetURL = indexed.url
        let descriptor = FetchDescriptor<FileEntity>(predicate: #Predicate { $0.pathURL == targetURL })
        if let existing = try context.fetch(descriptor).first {
            // update metadata if needed
            existing.updateMetadata(from: FileAttributes(fileName: indexed.fileName, fileType: indexed.fileType, fileSize: indexed.fileSize, createdDate: indexed.createdDate, modifiedDate: indexed.modifiedDate))
            existing.markIndexed(date: indexed.indexedDate ?? Date())
            if existing.embedding == nil, let emb = indexed.embedding {
                let embEntity = EmbeddingEntity(vector: emb.vector, keywords: emb.keywords, analysisTimestamp: emb.analysisTimestamp)
                context.insert(embEntity)
                existing.embedding = embEntity
            }
            return existing
        } else {
            // create new FileEntity and EmbeddingEntity if embedding present
            let fileEntity = FileEntity(pathURL: indexed.url, fileName: indexed.fileName, fileType: indexed.fileType, fileSize: indexed.fileSize, createdDate: indexed.createdDate, modifiedDate: indexed.modifiedDate, indexedDate: indexed.indexedDate)
            context.insert(fileEntity)
            if let emb = indexed.embedding {
                let embEntity = EmbeddingEntity(vector: emb.vector, keywords: emb.keywords, analysisTimestamp: emb.analysisTimestamp)
                context.insert(embEntity)
                fileEntity.embedding = embEntity
            }
            return fileEntity
        }
    }
}
