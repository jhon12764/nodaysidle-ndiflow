import Foundation
import SwiftData
import OSLog

/// Service responsible for workspace-level aggregation and incremental updates.
/// - Provides clustering operations over sets of `IndexedFile` values and handles
///   workspace membership updates in response to filesystem events.
/// - Interacts with `PersistenceController` for SwiftData persistence to update
///   `WorkspaceEntity`, `WorkspaceMembership`, `FileEntity` and `EmbeddingEntity`.
@MainActor
final class WorkspaceAggregationService {
    static let shared = WorkspaceAggregationService()

    private let logger = Logger(subsystem: "com.ndiflow.app", category: "WorkspaceAggregation")

    // Dependencies
    private let clusteringEngine = ClusteringEngine.self

    private init() {}

    // MARK: - API (Clustering)

    /// Cluster an array of `IndexedFile` values using the agglomerative single-link algorithm.
    /// - Parameters:
    ///   - files: files to cluster (should include embeddings for meaningful clusters)
    ///   - threshold: similarity threshold (0.0..1.0)
    /// - Returns: array of `FileCluster` grouped by semantic similarity
    func clusterFiles(_ files: [IndexedFile], threshold: Float) throws -> [FileCluster] {
        logger.log("Clustering \(files.count) files with threshold \(threshold)")
        // Filter to those with embeddings - ClusteringEngine will throw if no embeddings at all.
        let candidates = files.filter { $0.embedding != nil && !$0.embedding!.isZeroVector }
        if candidates.isEmpty {
            logger.debug("No embedded files supplied to clusterFiles; returning empty array.")
            return []
        }

        // Delegate to ClusteringEngine (may throw)
        let clusters = try clusteringEngine.clusterFiles(candidates, threshold: threshold)
        logger.log("Clustering produced \(clusters.count) clusters")
        return clusters
    }

    // MARK: - API (Workspace incremental updates)

    /// Update a workspace in response to a file system event. Performs indexing (if needed),
    /// and then updates workspace memberships incrementally based on similarity to workspace centroid.
    ///
    /// - Parameters:
    ///   - workspace: the `WorkspaceEntity` to update (identity used to re-fetch in background context)
    ///   - event: the `FileSystemEvent` describing the change
    ///   - forceAdd: if true, bypasses similarity check and adds all files (useful for initial scans)
    /// - Returns: the updated `WorkspaceEntity` (from the background context) after applying the event
    func updateWorkspace(_ workspace: WorkspaceEntity, withEvent event: FileSystemEvent, forceAdd: Bool = false) async throws -> WorkspaceEntity {
        let eventTypeStr = String(describing: event.eventType)
        logger.log("Processing event \(eventTypeStr, privacy: .public) for path \(event.filePath.path, privacy: .public) on workspace \(workspace.name, privacy: .public)")

        // Use the main context since we're on @MainActor
        let context = PersistenceController.shared.mainContext

        // Use the workspace directly since it's already in the main context
        let wsInContext = workspace

        switch event.eventType {
        case .created, .modified:
            // Index the file (synchronously from this async context via IndexingCoordinator).
            // Note: indexFile will persist FileEntity + EmbeddingEntity.
            let indexed = try await IndexingCoordinator.shared.indexFile(at: event.filePath)

            guard let embedding = indexed.embedding, !embedding.isZeroVector else {
                logger.debug("Indexed file has no embedding; skipping membership update: \(event.filePath.path, privacy: .public)")
                return wsInContext
            }

            // Recompute workspace centroid if needed
            var centroid: [Float]? = wsInContext.centroidVector
            if centroid == nil {
                // Build centroid from current memberships if possible
                var memberVectors: [[Float]] = []
                for m in wsInContext.memberships {
                    if let file = m.file, let emb = file.embedding {
                        memberVectors.append(emb.vector)
                    }
                }
                if !memberVectors.isEmpty {
                    centroid = VectorMath.average(of: memberVectors)
                    wsInContext.centroidVector = centroid
                }
            }

            if let centroid = centroid {
                // Compute similarity to workspace centroid
                let similarity = VectorMath.cosineSimilarity(centroid, embedding.vector)
                logger.log("Similarity to workspace centroid: \(similarity) (threshold: \(wsInContext.clusteringThreshold))")
                if forceAdd || wsInContext.shouldIncludeFile(similarity: similarity) {
                    // Upsert membership with similarity score
                    let fileEntity = try resolveOrCreateFileEntity(for: indexed, context: context)
                    wsInContext.upsertMembership(for: fileEntity, similarity: similarity)
                    // Recompute centroid after insert
                    _ = wsInContext.recomputeCentroid()
                    try context.save()
                    logger.log("Added/updated membership for \(indexed.fileName, privacy: .public) in workspace \(wsInContext.name, privacy: .public)")
                } else {
                    logger.log("File \(indexed.fileName, privacy: .public) not similar enough to workspace centroid; not added.")
                }
            } else {
                // No existing centroid; treat file as seed for workspace
                let fileEntity = try resolveOrCreateFileEntity(for: indexed, context: context)
                wsInContext.upsertMembership(for: fileEntity, similarity: 1.0)
                _ = wsInContext.recomputeCentroid()
                try context.save()
                logger.log("Workspace had no centroid; seeded with \(indexed.fileName, privacy: .public)")
            }

        case .deleted:
            // Find FileEntity by path and remove membership if present
            if let fileEntity = try fetchFileEntity(byPath: event.filePath, context: context) {
                wsInContext.removeMembership(for: fileEntity)
                // Optionally delete membership objects or let cascade semantics apply.
                _ = wsInContext.recomputeCentroid()
                try context.save()
                logger.log("Removed membership for deleted file: \(event.filePath.path, privacy: .public)")
            } else {
                logger.debug("Deleted file had no persisted FileEntity: \(event.filePath.path, privacy: .public)")
            }

        case .renamed:
            // Handle rename: map oldPath -> newPath
            if let old = event.oldPath {
                // Try to find membership by old path
                if let fileEntity = try fetchFileEntity(byPath: old, context: context) {
                    // Update the fileEntity.pathURL to the new path
                    fileEntity.pathURL = event.filePath
                    // Update associated fileName and modifiedDate from FS where possible
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: event.filePath.path) {
                        if let mod = attrs[.modificationDate] as? Date {
                            fileEntity.modifiedDate = mod
                        }
                        fileEntity.fileName = event.filePath.lastPathComponent
                    }
                    // Recompute similarity to workspace and update membership score
                    if let emb = fileEntity.embedding {
                        if let centroid = wsInContext.centroidVector {
                            let sim = VectorMath.cosineSimilarity(centroid, emb.vector)
                            wsInContext.upsertMembership(for: fileEntity, similarity: sim)
                        }
                    }
                    _ = wsInContext.recomputeCentroid()
                    try context.save()
                    logger.log("Handled rename: \(old.path, privacy: .public) -> \(event.filePath.path, privacy: .public)")
                } else {
                    // Old file not found; treat as a create for the new path
                    logger.debug("Rename old-path not found in DB; treating new path as created.")
                    let pseudoEvent = FileSystemEvent(eventType: .created, filePath: event.filePath, oldPath: nil)
                    // Recursively call updateWorkspace for created case.
                    _ = try await updateWorkspace(wsInContext, withEvent: pseudoEvent)
                }
            } else {
                logger.debug("Rename event missing oldPath; skipping.")
            }
        }

        // Return the workspace instance as present in this background context.
        return wsInContext
    }

    // MARK: - Helpers (persistence)

    /// Resolve an existing `FileEntity` for the given `IndexedFile`, or create one if not present.
    /// Ensures that a `FileEntity` exists in the provided `context` and returns it.
    private func resolveOrCreateFileEntity(for indexed: IndexedFile, context: ModelContext) throws -> FileEntity {
        // Try to find existing FileEntity by pathURL
        let targetURL = indexed.url
        let descriptor = FetchDescriptor<FileEntity>(predicate: #Predicate { $0.pathURL == targetURL })
        if let existing = try context.fetch(descriptor).first {
            // Update metadata and indexed date
            existing.updateMetadata(from: FileAttributes(fileName: indexed.fileName, fileType: indexed.fileType, fileSize: indexed.fileSize, createdDate: indexed.createdDate, modifiedDate: indexed.modifiedDate))
            existing.markIndexed(date: indexed.indexedDate ?? Date())
            // Ensure embedding link exists (create EmbeddingEntity if missing)
            if existing.embedding == nil, let emb = indexed.embedding {
                let embEntity = EmbeddingEntity(vector: emb.vector, keywords: emb.keywords, analysisTimestamp: emb.analysisTimestamp)
                context.insert(embEntity)
                existing.embedding = embEntity
            }
            return existing
        } else {
            // Create new FileEntity and EmbeddingEntity
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

    /// Fetch a `FileEntity` by its filesystem path in the given context.
    private func fetchFileEntity(byPath path: URL, context: ModelContext) throws -> FileEntity? {
        let descriptor = FetchDescriptor<FileEntity>(predicate: #Predicate { $0.pathURL == path })
        return try context.fetch(descriptor).first
    }
}
