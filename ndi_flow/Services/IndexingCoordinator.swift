import Foundation
import SwiftData
import OSLog

/// Progress structure emitted by `rebuildIndex(for:)`.
struct IndexingProgress: Sendable {
    let total: Int
    let completed: Int
    let currentFile: URL?
    let errors: [Error]

    init(total: Int, completed: Int, currentFile: URL? = nil, errors: [Error] = []) {
        self.total = total
        self.completed = completed
        self.currentFile = currentFile
        self.errors = errors
    }
}

/// Service responsible for coordinating file indexing work.
/// - Concurrency: Uses structured concurrency and limits parallel indexing to `maxConcurrentIndexing`.
@MainActor
final class IndexingCoordinator {
    static let shared = IndexingCoordinator()

    private let logger = Logger.indexing

    /// Maximum number of concurrent indexing tasks.
    private let maxConcurrentIndexing: Int = 4

    private init() {}

    /// Index a single file at the provided URL.
    /// - Parameter url: File URL to index.
    /// - Returns: `IndexedFile` representing the resulting index state.
    /// - Throws: Errors encountered during metadata extraction, analysis, or persistence.
    func indexFile(at url: URL) async throws -> IndexedFile {
        logger.log("Indexing request for: \(url.path, privacy: .public)")

        // Build initial IndexedFile from filesystem metadata
        let indexedFile: IndexedFile
        do {
            indexedFile = try IndexedFile(from: url)
        } catch {
            logger.error("Failed to read file metadata for \(url.path, privacy: .public): \(String(describing: error))")
            throw error
        }

        // Mark analyzing locally and proceed with semantic analysis
        let working = indexedFile.markingAnalyzing()

        do {
            let embedding: SemanticEmbedding

            if working.isDocumentType {
                logger.log("Routing to document analyzer for: \(working.url.path, privacy: .public)")
                embedding = try await SemanticAnalysisService.shared.analyzeDocument(working.url)
            } else if working.isImageType {
                logger.log("Routing to image analyzer for: \(working.url.path, privacy: .public)")
                embedding = try await SemanticAnalysisService.shared.analyzeImage(working.url)
            } else {
                // For unknown types, perform a best-effort attempt: try document analysis first.
                logger.debug("Unknown file type for \(working.url.path, privacy: .public) — attempting document analysis fallback.")
                embedding = try await SemanticAnalysisService.shared.analyzeDocument(working.url)
            }

            // Persist to SwiftData using main context (we're on @MainActor)
            let context = PersistenceController.shared.mainContext

            // Create or update FileEntity and EmbeddingEntity
            // Try to find existing FileEntity by path
            let targetURL = working.url
            let descriptor = FetchDescriptor<FileEntity>(predicate: #Predicate { $0.pathURL == targetURL })
            let existing = try? context.fetch(descriptor).first

            let fileEntity: FileEntity
            if let exist = existing {
                // Update metadata
                exist.updateMetadata(from: FileAttributes(fileName: working.fileName, fileType: working.fileType, fileSize: working.fileSize, createdDate: working.createdDate, modifiedDate: working.modifiedDate))
                exist.markIndexed(date: Date())
                fileEntity = exist
            } else {
                fileEntity = FileEntity(pathURL: working.url, fileName: working.fileName, fileType: working.fileType, fileSize: working.fileSize, createdDate: working.createdDate, modifiedDate: working.modifiedDate, indexedDate: Date())
                context.insert(fileEntity)
            }

            // Create EmbeddingEntity and attach via FileEntity.embedding only
            // (setting from one side lets SwiftData handle the inverse relationship)
            let embeddingEntity = EmbeddingEntity(vector: embedding.vector, keywords: embedding.keywords, analysisTimestamp: embedding.analysisTimestamp)
            context.insert(embeddingEntity)
            fileEntity.embedding = embeddingEntity

            try context.save()
            logger.log("Persisted FileEntity and EmbeddingEntity for \(working.url.path, privacy: .public)")

            // Return success IndexedFile
            return working.markingIndexed(with: embedding, at: Date())
        } catch {
            logger.error("Indexing failed for \(url.path, privacy: .public): \(String(describing: error))")
            let failed = working.markingFailed(String(describing: error))
            return failed
        }
    }

    /// Rebuild the index for a given workspace by re-indexing all files referenced by the workspace's memberships.
    /// Emits `IndexingProgress` updates via the returned `AsyncStream`.
    ///
    /// - Parameter workspace: `WorkspaceEntity` to rebuild index for.
    /// - Returns: `AsyncStream<IndexingProgress>` emitting progress updates and completing when rebuild finishes.
    func rebuildIndex(for workspace: WorkspaceEntity) -> AsyncStream<IndexingProgress> {
        // Snapshot targeted file URLs from the workspace memberships.
        let fileURLs: [URL] = workspace.memberships.compactMap { $0.file?.pathURL }

        return AsyncStream { continuation in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                let total = fileURLs.count
                var completed = 0
                var errors: [Error] = []

                // Emit initial progress
                continuation.yield(IndexingProgress(total: total, completed: completed, currentFile: nil, errors: errors))

                if total == 0 {
                    continuation.yield(IndexingProgress(total: 0, completed: 0, currentFile: nil, errors: []))
                    continuation.finish()
                    return
                }

                // Process files sequentially to avoid data race issues
                for url in fileURLs {
                    if Task.isCancelled {
                        break
                    }

                    continuation.yield(IndexingProgress(total: total, completed: completed, currentFile: url, errors: errors))

                    do {
                        _ = try await self.indexFile(at: url)
                        completed += 1
                    } catch {
                        completed += 1
                        errors.append(error)
                        self.logger.error("Error indexing \(url.path, privacy: .public): \(String(describing: error))")
                    }

                    continuation.yield(IndexingProgress(total: total, completed: completed, currentFile: nil, errors: errors))
                }

                // Final progress
                continuation.yield(IndexingProgress(total: total, completed: completed, currentFile: nil, errors: errors))
                continuation.finish()
            }
        }
    }
}
