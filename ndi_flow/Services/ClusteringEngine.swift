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
/// - Complexity: naive O(n^3) in the worst-case for n files; acceptable for moderate workspace sizes.
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

        // Create initial clusters: one cluster per file.
        var clusters: [FileCluster] = files.map { file in
            var c = FileCluster(files: [file])
            _ = c.recomputeCentroid()
            return c
        }

        // Quick check: ensure at least one embedding exists; otherwise we cannot compute similarities.
        let anyEmbeddingExists = clusters.contains { !$0.memberEmbeddings.isEmpty }
        if !anyEmbeddingExists {
            // No embeddings: return the single-file clusters as-is (or throw depending on caller preference).
            logger.debug("No embeddings found among files; returning single-file clusters.")
            throw ClusteringError.noEmbeddingsFound
        }

        // Helper: compute single-link similarity between two clusters:
        // defined as the maximum pairwise similarity between any member embeddings.
        func singleLinkSimilarity(_ a: FileCluster, _ b: FileCluster) -> Float {
            let aEmb = a.memberEmbeddings
            let bEmb = b.memberEmbeddings
            guard !aEmb.isEmpty, !bEmb.isEmpty else { return -1.0 } // treat missing embeddings as minimal similarity
            var best: Float = -1.0
            for va in aEmb {
                for vb in bEmb {
                    let sim = VectorMath.cosineSimilarity(va, vb)
                    if sim > best { best = sim }
                }
            }
            return best
        }

        // Iteratively merge clusters using the single-link criterion until no pair meets threshold.
        while true {
            var bestSim: Float = -2.0
            var bestPair: (Int, Int)? = nil

            // Evaluate all pairs (i, j) with i < j
            let n = clusters.count
            if n <= 1 { break }

            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    let sim = singleLinkSimilarity(clusters[i], clusters[j])
                    if sim > bestSim {
                        bestSim = sim
                        bestPair = (i, j)
                    }
                }
            }

            // If best similarity does not meet threshold, stop merging.
            guard let pair = bestPair, bestSim >= threshold else {
                break
            }

            // Merge clusters[pair.0] and clusters[pair.1]
            let (i, j) = pair
            logger.debug("Merging clusters \(clusters[i].id) and \(clusters[j].id) with similarity \(bestSim) (threshold: \(threshold))")

            // Build merged files array and create new cluster
            var mergedFiles = clusters[i].files + clusters[j].files
            var mergedCluster = FileCluster(files: mergedFiles)
            _ = mergedCluster.recomputeCentroid()

            // Remove the two clusters and append the merged one.
            // Remove the higher index first to keep indices valid.
            if j > i {
                clusters.remove(at: j)
                clusters.remove(at: i)
            } else {
                clusters.remove(at: i)
                clusters.remove(at: j)
            }
            clusters.append(mergedCluster)
        }

        // Final recompute for all clusters to ensure centroids/coherences are accurate.
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
