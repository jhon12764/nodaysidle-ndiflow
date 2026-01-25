//
//  FileCluster.swift
//  ndi_flow
//
//  Represents a semantic cluster of indexed files with centroid and coherence score.
//
//  Target: macOS 15+, Swift 6
//

import Foundation

/// A cluster of related files produced by a clustering algorithm.
/// - `files` contains the member `IndexedFile` values (with embeddings when available)
/// - `centroid` is a dense float vector representing the cluster center (nil when not computable)
/// - `coherenceScore` is the average cosine similarity of members to the centroid (0.0..1.0 typically)
public struct FileCluster: Identifiable, Sendable, Hashable {
    public let id: UUID

    /// Member files. IndexedFile is a value-type; keep members as an array for easy iteration.
    public private(set) var files: [IndexedFile]

    /// Computed centroid vector for this cluster. Nil when no valid embeddings are present.
    public private(set) var centroid: [Float]?

    /// Coherence score: average similarity of member embeddings to centroid.
    /// Range is approximately -1.0 ... 1.0, but practically 0.0 ... 1.0 for typical positive-semantic spaces.
    public private(set) var coherenceScore: Float

    public init(id: UUID = UUID(), files: [IndexedFile] = [], centroid: [Float]? = nil, coherenceScore: Float = 0.0) {
        self.id = id
        self.files = files
        self.centroid = centroid
        self.coherenceScore = coherenceScore
    }

    // MARK: - Computation

    /// Compute centroid from current member embeddings. Uses VectorMath.average to produce the mean vector.
    /// If no valid embeddings exist among members, centroid is set to nil and coherenceScore to 0.0.
    /// - Returns: the computed centroid vector or nil.
    @discardableResult
    public mutating func recomputeCentroid() -> [Float]? {
        // Collect all non-nil embeddings from members
        let embeddings = files.compactMap { $0.embedding?.vector }
        guard !embeddings.isEmpty else {
            centroid = nil
            coherenceScore = 0.0
            return nil
        }

        // Use VectorMath.average to compute centroid (handles dimension checks)
        let newCentroid = VectorMath.average(of: embeddings)
        centroid = newCentroid

        // Update coherence score
        if let c = newCentroid {
            coherenceScore = computeCoherence(with: c, memberVectors: embeddings)
        } else {
            coherenceScore = 0.0
        }
        return centroid
    }

    /// Compute centroid without changing stored state. Returns nil when no valid embeddings.
    public func centroidComputed() -> [Float]? {
        let embeddings = files.compactMap { $0.embedding?.vector }
        guard !embeddings.isEmpty else { return nil }
        return VectorMath.average(of: embeddings)
    }

    /// Compute the coherence score (average cosine similarity to centroid) for supplied centroid and embeddings.
    /// - Parameters:
    ///   - centroid: centroid vector
    ///   - memberVectors: list of member vectors
    /// - Returns: average cosine similarity (Float)
    private func computeCoherence(with centroid: [Float], memberVectors: [[Float]]) -> Float {
        guard !memberVectors.isEmpty else { return 0.0 }
        var sum: Float = 0.0
        var count: Int = 0
        for vec in memberVectors {
            if vec.count == centroid.count {
                let sim = VectorMath.cosineSimilarity(centroid, vec)
                sum += sim
                count += 1
            }
        }
        guard count > 0 else { return 0.0 }
        return sum / Float(count)
    }

    // MARK: - Membership operations

    /// Add a new file to the cluster and update centroid/coherence incrementally.
    /// If the file has no embedding, it's still added but centroid/coherence may not change.
    /// - Parameter file: IndexedFile to add.
    public mutating func add(_ file: IndexedFile) {
        files.append(file)
        // If file has embedding, try to incrementally update centroid for efficiency.
        guard let fileVec = file.embedding?.vector else {
            // No embedding -> recompute only if centroid is nil (to compute from other members)
            if centroid == nil {
                _ = recomputeCentroid()
            }
            return
        }

        if var c = centroid {
            // incremental average: newCentroid = (c * n + v) / (n + 1)
            let n = Float(max(files.count - 1, 0))
            let inv = 1.0 / Float(n + 1.0)
            var updated = [Float](repeating: 0.0, count: c.count)
            for i in 0..<c.count {
                let prev = c[i] * n
                let added = (i < fileVec.count) ? fileVec[i] : 0.0
                updated[i] = (prev + added) * inv
            }
            centroid = updated
            // Update coherence: recompute properly for correctness
            let embeddings = files.compactMap { $0.embedding?.vector }
            coherenceScore = computeCoherence(with: updated, memberVectors: embeddings)
        } else {
            // No centroid yet; recompute fully
            _ = recomputeCentroid()
        }
    }

    /// Remove files matching the provided predicate. Returns removed files.
    /// Updates centroid/coherence after removal.
    /// - Parameter shouldRemove: predicate returning true for files to remove
    /// - Returns: removed files array
    @discardableResult
    public mutating func remove(where shouldRemove: (IndexedFile) -> Bool) -> [IndexedFile] {
        let (kept, removed) = files.partitioned(by: shouldRemove)
        files = kept
        // Recompute centroid after removal for correctness
        _ = recomputeCentroid()
        return removed
    }

    /// Replace the cluster's members wholesale and recompute centroid/coherence.
    /// - Parameter newFiles: new members
    public mutating func replaceMembers(with newFiles: [IndexedFile]) {
        files = newFiles
        _ = recomputeCentroid()
    }

    // MARK: - Utilities

    /// Returns number of member files in the cluster.
    public var memberCount: Int {
        files.count
    }

    /// Returns all member embeddings (non-nil) in the cluster.
    public var memberEmbeddings: [[Float]] {
        files.compactMap { $0.embedding?.vector }
    }

    // MARK: - Equality / Hashing

    public static func == (lhs: FileCluster, rhs: FileCluster) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Small helpers

private extension Array {
    /// Partition array into elements that do not match predicate (kept) and those that do (removed).
    /// Returns (kept, removed)
    func partitioned(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var kept: [Element] = []
        var removed: [Element] = []
        for el in self {
            if predicate(el) {
                removed.append(el)
            } else {
                kept.append(el)
            }
        }
        return (kept, removed)
    }
}
