//
//  WorkspaceEntity.swift
//  ndi_flow
//
//  SwiftData @Model representing a semantic Workspace and its membership join entity.
//
//  - `WorkspaceEntity` stores workspace configuration (name, threshold, centroid).
//  - `WorkspaceMembership` is a join entity that links a `FileEntity` to a `WorkspaceEntity`
//    and stores the similarity score used to determine membership.
//  - Centroid vector is optional and can be recalculated from member embeddings.
//
//  Target: macOS 15+, Swift 6, SwiftData
//

import Foundation
import SwiftData

@Model
final class WorkspaceEntity: Identifiable {
    // Primary identifier
    var id: UUID

    // User-visible name for the workspace
    var name: String

    // Creation timestamp
    var createdDate: Date

    // Clustering similarity threshold (0.0 ... 1.0)
    // Files with similarity >= clusteringThreshold are considered members
    var clusteringThreshold: Float

    // Centroid embedding vector representing the workspace semantic center.
    // `nil` when not computed yet.
    var centroidVector: [Float]?

    // To-many relationship to membership join entities.
    // Inverse is declared on WorkspaceMembership as `workspace`.
    @Relationship(inverse: \WorkspaceMembership.workspace)
    var memberships: [WorkspaceMembership]

    init(
        id: UUID = UUID(),
        name: String,
        createdDate: Date = Date(),
        clusteringThreshold: Float = 0.75,
        centroidVector: [Float]? = nil,
        memberships: [WorkspaceMembership] = []
    ) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.clusteringThreshold = clusteringThreshold
        self.centroidVector = centroidVector
        self.memberships = memberships
    }

    // Convenience computed properties

    var fileCount: Int {
        memberships.count
    }

    var isEmpty: Bool {
        memberships.isEmpty
    }

    // Recalculate the centroid vector from current members' embeddings.
    // Uses EmbeddingEntity.dimension if available; otherwise requires at least one embedding to infer length.
    // Returns the new centroid vector or nil if no valid embeddings present.
    func recomputeCentroid() -> [Float]? {
        // Gather all valid embedding vectors from membership file embeddings
        var vectors: [[Float]] = []
        for membership in memberships {
            if let file = membership.file,
               let embedding = file.embedding {
                vectors.append(embedding.vector)
            }
        }

        guard !vectors.isEmpty else {
            centroidVector = nil
            return nil
        }

        // Use dimension from first vector (prefer EmbeddingEntity.dimension if available)
        let dimension = vectors.first!.count
        var centroid = Array(repeating: Float(0.0), count: dimension)

        // Sum vectors element-wise
        for vec in vectors {
            // Skip mismatched dimensions to keep centroid consistent
            guard vec.count == dimension else { continue }
            for i in 0..<dimension {
                centroid[i] += vec[i]
            }
        }

        // Average
        let countInv = 1.0 / Float(vectors.count)
        for i in 0..<dimension {
            centroid[i] *= countInv
        }

        centroidVector = centroid
        return centroid
    }

    // Update membership similarity for a given file.
    // If file is already a member, update similarityScore; otherwise create a membership.
    // Note: Persistence (inserting/updating models) should be performed within a ModelContext elsewhere.
    func upsertMembership(for file: FileEntity, similarity: Float) {
        if let existingIndex = memberships.firstIndex(where: { $0.file?.id == file.id }) {
            memberships[existingIndex].similarityScore = similarity
            memberships[existingIndex].updatedDate = Date()
        } else {
            let membership = WorkspaceMembership(workspace: self, file: file, similarityScore: similarity)
            memberships.append(membership)
        }
    }

    // Remove membership for a given file (if present).
    func removeMembership(for file: FileEntity) {
        memberships.removeAll { $0.file?.id == file.id }
    }

    // Find the maximum similarity among members
    var maxSimilarity: Float {
        memberships.map { $0.similarityScore }.max() ?? 0.0
    }

    // Helper to determine if a file should be a member given its similarity
    func shouldIncludeFile(similarity: Float) -> Bool {
        similarity >= clusteringThreshold
    }
}


/// Join entity linking a WorkspaceEntity to a FileEntity with a similarity score.
///
/// This model allows storing workspace-specific membership metadata (e.g. similarity score)
/// rather than storing workspace references directly on FileEntity. It enables many-to-many
/// semantics in a normalized way and allows attaching per-membership metadata.
@Model
final class WorkspaceMembership: Identifiable {
    var id: UUID

    // Relationship to WorkspaceEntity - inverse is declared on WorkspaceEntity.memberships
    var workspace: WorkspaceEntity?

    // Relationship to the indexed file.
    // We intentionally do not declare an inverse on FileEntity here to avoid requiring
    // a dedicated `workspaces` property on FileEntity in this iteration. It is possible
    // to add an inverse like `@Relationship(inverse: \FileEntity.workspaceMemberships)` later.
    @Relationship
    var file: FileEntity?

    // Similarity score of the file to the workspace centroid (range -1...1, typically 0...1)
    var similarityScore: Float

    // Timestamps for auditing membership changes
    var createdDate: Date
    var updatedDate: Date

    init(
        id: UUID = UUID(),
        workspace: WorkspaceEntity? = nil,
        file: FileEntity? = nil,
        similarityScore: Float,
        createdDate: Date = Date(),
        updatedDate: Date = Date()
    ) {
        self.id = id
        self.workspace = workspace
        self.file = file
        self.similarityScore = similarityScore
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }
}
