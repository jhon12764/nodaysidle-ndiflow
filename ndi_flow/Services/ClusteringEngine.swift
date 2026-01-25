import Foundation
import OSLog

/// Agglomerative single-link clustering engine.
///
/// Performs hierarchical clustering using the single-link (minimum distance / maximum similarity)
/// linkage criterion. Clusters are merged iteratively by selecting the pair of clusters with the
/// highest inter-cluster similarity (single-link) until no pair exceeds the provided threshold.
///
/// Notes:
/// - Embeddings are expected to be present on `IndexedFile.embedding`. Files without embeddings
///   will remain as single-file clusters and will not be merged with others (they have no semantic vector).
/// - Similarity metric: cosine similarity (via `VectorMath.cosineSimilarity`).
/// - Complexity: O(n² log n) using a priority queue with lazy deletion.
/// - The returned clusters contain recomputed centroids and coherence scores via `FileCluster.recomputeCentroid()`.
public enum ClusteringError: Error, LocalizedError {
    case insufficientData
    case noEmbeddingsFound

    public var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "Insufficient data provided for clustering."
        case .noEmbeddingsFound:
            return "No embeddings available among the provided files."
        }
    }
}

/// A candidate merge pair for the priority queue.
private struct MergeCandidate: Comparable {
    let clusterID1: UUID
    let clusterID2: UUID
    let similarity: Float

    static func < (lhs: MergeCandidate, rhs: MergeCandidate) -> Bool {
        // We want a max-heap, so higher similarity = higher priority
        lhs.similarity < rhs.similarity
    }
}

/// A simple max-heap implementation for merge candidates.
private struct MergeCandidateHeap {
    private var elements: [MergeCandidate] = []

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    mutating func insert(_ candidate: MergeCandidate) {
        elements.append(candidate)
        siftUp(elements.count - 1)
    }

    mutating func popMax() -> MergeCandidate? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements.removeLast() }
        let max = elements[0]
        elements[0] = elements.removeLast()
        siftDown(0)
        return max
    }

    func peek() -> MergeCandidate? {
        elements.first
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && elements[child] > elements[parent] {
            elements.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        let count = elements.count
        while true {
            let left = 2 * parent + 1
            let right = 2 * parent + 2
            var largest = parent

            if left < count && elements[left] > elements[largest] {
                largest = left
            }
            if right < count && elements[right] > elements[largest] {
                largest = right
            }
            if largest == parent { break }
            elements.swapAt(parent, largest)
            parent = largest
        }
    }
}

public struct ClusteringEngine {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ndiflow.app", category: "Clustering")

    /// Perform agglomerative single-link clustering on the provided indexed files.
    ///
    /// - Parameters:
    ///   - files: Array of `IndexedFile` values to cluster. Files without embeddings are allowed and will
    ///            be returned as single-file clusters.
    ///   - threshold: Similarity threshold in [0.0, 1.0]. Clusters are merged while the highest inter-cluster
    ///                similarity is >= threshold.
    /// - Returns: Array of `FileCluster` representing clustered files. Clusters are sorted by descending size.
    public static func clusterFiles(_ files: [IndexedFile], threshold: Float) throws -> [FileCluster] {
        guard !files.isEmpty else {
            throw ClusteringError.insufficientData
        }

        // Create initial clusters: one cluster per file, tracked by UUID.
        var clusterMap: [UUID: FileCluster] = [:]
        for file in files {
            var c = FileCluster(files: [file])
            _ = c.recomputeCentroid()
            clusterMap[c.id] = c
        }

        // Quick check: ensure at least one embedding exists.
        let anyEmbeddingExists = clusterMap.values.contains { !$0.memberEmbeddings.isEmpty }
        if !anyEmbeddingExists {
            logger.debug("No embeddings found among files; returning single-file clusters.")
            throw ClusteringError.noEmbeddingsFound
        }

        // Helper: compute single-link similarity between two clusters.
        func singleLinkSimilarity(_ a: FileCluster, _ b: FileCluster) -> Float {
            let aEmb = a.memberEmbeddings
            let bEmb = b.memberEmbeddings
            guard !aEmb.isEmpty, !bEmb.isEmpty else { return -1.0 }
            var best: Float = -1.0
            for va in aEmb {
                for vb in bEmb {
                    let sim = VectorMath.cosineSimilarity(va, vb)
                    if sim > best { best = sim }
                }
            }
            return best
        }

        // Initialize priority queue with all pairwise similarities.
        var heap = MergeCandidateHeap()
        let clusterIDs = Array(clusterMap.keys)
        let n = clusterIDs.count

        for i in 0..<(n - 1) {
            guard let clusterA = clusterMap[clusterIDs[i]] else { continue }
            for j in (i + 1)..<n {
                guard let clusterB = clusterMap[clusterIDs[j]] else { continue }
                let sim = singleLinkSimilarity(clusterA, clusterB)
                if sim >= threshold {
                    heap.insert(MergeCandidate(
                        clusterID1: clusterIDs[i],
                        clusterID2: clusterIDs[j],
                        similarity: sim
                    ))
                }
            }
        }

        // Track active cluster IDs for lazy deletion.
        var activeClusterIDs = Set(clusterIDs)

        // Iteratively merge clusters using lazy deletion from the heap.
        while let candidate = heap.popMax() {
            // Lazy deletion: skip if either cluster was already merged.
            guard activeClusterIDs.contains(candidate.clusterID1),
                  activeClusterIDs.contains(candidate.clusterID2) else {
                continue
            }

            // Check threshold (candidates below threshold shouldn't be in heap, but double-check).
            guard candidate.similarity >= threshold else {
                continue
            }

            guard let clusterA = clusterMap[candidate.clusterID1],
                  let clusterB = clusterMap[candidate.clusterID2] else {
                continue
            }

            logger.debug("Merging clusters \(clusterA.id) and \(clusterB.id) with similarity \(candidate.similarity) (threshold: \(threshold))")

            // Create merged cluster.
            let mergedFiles = clusterA.files + clusterB.files
            var mergedCluster = FileCluster(files: mergedFiles)
            _ = mergedCluster.recomputeCentroid()

            // Remove old clusters, add new one.
            activeClusterIDs.remove(candidate.clusterID1)
            activeClusterIDs.remove(candidate.clusterID2)
            clusterMap.removeValue(forKey: candidate.clusterID1)
            clusterMap.removeValue(forKey: candidate.clusterID2)

            let newID = mergedCluster.id
            clusterMap[newID] = mergedCluster
            activeClusterIDs.insert(newID)

            // Add new merge candidates between the merged cluster and all remaining clusters.
            for otherID in activeClusterIDs where otherID != newID {
                guard let otherCluster = clusterMap[otherID] else { continue }
                let sim = singleLinkSimilarity(mergedCluster, otherCluster)
                if sim >= threshold {
                    heap.insert(MergeCandidate(
                        clusterID1: newID,
                        clusterID2: otherID,
                        similarity: sim
                    ))
                }
            }
        }

        // Final recompute for all clusters to ensure centroids/coherences are accurate.
        var clusters = Array(clusterMap.values)
        for idx in clusters.indices {
            _ = clusters[idx].recomputeCentroid()
        }

        // Sort clusters by size (descending) then by coherence (descending).
        clusters.sort {
            if $0.memberCount != $1.memberCount {
                return $0.memberCount > $1.memberCount
            }
            return $0.coherenceScore > $1.coherenceScore
        }

        return clusters
    }
}
