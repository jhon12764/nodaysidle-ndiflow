//
//  VectorMath.swift
//  ndi_flow
//
//  Utilities for vector math using Accelerate (vDSP).
//  Provides cosine similarity, normalization and basic helpers optimized with Accelerate.
//
//  Target: macOS 15+, Swift 6
//

import Foundation
import Accelerate

/// High-performance vector math helpers using Accelerate framework.
///
/// - Notes:
///   - Functions operate on `[Float]` vectors (single-precision) which match the embedding
///     representation used elsewhere in the project.
///   - Where possible operations are implemented using vDSP C APIs for predictable performance.
public enum VectorMath {
    /// Compute the dot product of two same-length float vectors.
    /// - Returns: dot(a, b) or 0.0 if lengths mismatch or length == 0.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 0 else { return 0.0 }
        var result: Float = 0.0
        // vDSP_dotpr expects pointers to floats and a vDSP_Length
        a.withUnsafeBufferPointer { aPtr in
            b.withUnsafeBufferPointer { bPtr in
                vDSP_dotpr(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &result, vDSP_Length(a.count))
            }
        }
        return result
    }

    /// Compute the squared L2 norm (sum of squares) of a vector.
    /// - Returns: sum(x_i^2)
    public static func sumOfSquares(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0.0 }
        var result: Float = 0.0
        v.withUnsafeBufferPointer { ptr in
            vDSP_svesq(ptr.baseAddress!, 1, &result, vDSP_Length(v.count))
        }
        return result
    }

    /// Compute the L2 norm (Euclidean length) of a vector.
    /// - Returns: sqrt(sum(x_i^2))
    public static func l2Norm(_ v: [Float]) -> Float {
        let s = sumOfSquares(v)
        return s > 0 ? sqrt(s) : 0.0
    }

    /// Return an L2-normalized copy of the supplied vector.
    /// If the input is a zero-vector, the original vector is returned unchanged.
    public static func normalize(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let sumSq = sumOfSquares(v)
        guard sumSq > 0 else { return v } // cannot normalize zero-vector
        var invLen = 1.0 / Float(sqrt(sumSq))
        var out = Array(repeating: Float(0.0), count: v.count)
        v.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                // vDSP_vsmul multiplies each element by a scalar
                vDSP_vsmul(src.baseAddress!, 1, &invLen, dst.baseAddress!, 1, vDSP_Length(v.count))
            }
        }
        return out
    }

    /// Compute cosine similarity between two vectors.
    /// - Returns: Float in range [-1.0, 1.0]. Returns 0.0 if either vector is zero-length or lengths mismatch.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 0 else { return 0.0 }

        // Compute dot and norms using Accelerate
        var dotValue: Float = 0.0
        a.withUnsafeBufferPointer { aPtr in
            b.withUnsafeBufferPointer { bPtr in
                vDSP_dotpr(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &dotValue, vDSP_Length(a.count))
            }
        }

        let sumSqA = sumOfSquares(a)
        let sumSqB = sumOfSquares(b)

        guard sumSqA > 0, sumSqB > 0 else { return 0.0 }

        let denom = sqrt(sumSqA) * sqrt(sumSqB)
        guard denom != 0 else { return 0.0 }

        // Clamp the result to [-1, 1] to account for floating point imprecision
        var sim = dotValue / denom
        if sim > 1.0 { sim = 1.0 }
        if sim < -1.0 { sim = -1.0 }
        return sim
    }

    /// Compute cosine similarity but using pre-normalized vectors for slightly cheaper computation.
    /// - Both `a` and `b` must already be L2-normalized.
    /// - Returns: dot(a, b) or 0.0 if lengths mismatch.
    public static func cosineSimilarityNormalized(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 0 else { return 0.0 }
        return dot(a, b)
    }

    /// Compute the element-wise average of a list of vectors.
    /// - All vectors must have the same length.
    /// - Returns: The centroid vector, or nil if the input is empty or inconsistent.
    public static func average(of vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        let dim = vectors[0].count
        guard dim > 0 else { return nil }
        // Check all same dimension
        for v in vectors where v.count != dim {
            return nil
        }
        var result = [Float](repeating: 0.0, count: dim)
        for v in vectors {
            for i in 0..<dim {
                result[i] += v[i]
            }
        }
        let countInv = 1.0 / Float(vectors.count)
        for i in 0..<dim {
            result[i] *= countInv
        }
        return result
    }

    /// Batch compute cosine similarities between a single query vector and a list of candidate vectors.
    /// - The function handles non-normalized inputs by computing dot / (||q|| * ||c||) per candidate.
    /// - Returns: Array of similarity scores aligned with `candidates`. If lengths mismatch, the corresponding entry is 0.0.
    public static func batchCosineSimilarity(query: [Float], candidates: [[Float]]) -> [Float] {
        guard !query.isEmpty else { return candidates.map { _ in 0.0 } }
        var result = [Float]()
        result.reserveCapacity(candidates.count)

        // Precompute query norm
        let querySumSq = sumOfSquares(query)
        let queryNorm = querySumSq > 0 ? sqrt(querySumSq) : 0.0
        for cand in candidates {
            if cand.count != query.count || queryNorm == 0.0 {
                result.append(0.0)
                continue
            }
            // Use dot and candidate norm
            let d = dot(query, cand)
            let candNorm = l2Norm(cand)
            if candNorm == 0.0 { result.append(0.0); continue }
            var sim = d / (queryNorm * candNorm)
            if sim > 1.0 { sim = 1.0 }
            if sim < -1.0 { sim = -1.0 }
            result.append(sim)
        }
        return result
    }
}
