//
//  SemanticEmbedding.swift
//  ndi_flow
//
//  Defines the in-memory value type used to represent semantic analysis results
//  (embeddings, keywords/labels, confidence and analysis type).
//
//  Target: macOS 15+, Swift 6
//

import Foundation
import OSLog

/// Kind of analysis performed to produce the embedding.
public enum AnalysisType: String, Codable, Sendable {
    /// Embedding produced from textual/document content (PDF, TXT, RTF, DOCX, etc.)
    case document
    /// Embedding produced from visual/image content (JPEG, PNG, HEIC, etc.)
    case image
}

/// A lightweight, Sendable and Codable representation of a semantic embedding produced
/// by the SemanticAnalysisService. This is intended for passing analysis results
/// between actors and for temporary in-memory usage prior to persistence into `EmbeddingEntity`.
public struct SemanticEmbedding: Codable, Sendable, Equatable, Hashable {
    public static let dimension: Int = 512

    /// Dense float vector representing semantic content. Expected length == `SemanticEmbedding.dimension`.
    public var vector: [Float]

    /// Extracted keywords (primarily for document analysis).
    public var keywords: [String]

    /// Extracted labels (primarily for image analysis).
    public var labels: [String]

    /// The type of analysis that produced this embedding.
    public var analysisType: AnalysisType

    /// Confidence or strength (0.0 - 1.0) for the analysis / primary label. Optional: may be 0 when unknown.
    public var confidence: Float

    /// When the analysis was performed.
    public var analysisTimestamp: Date

    // MARK: - Initialization

    /// Create a SemanticEmbedding with a provided vector.
    /// If the vector length differs from `SemanticEmbedding.dimension`, it will be adjusted:
    /// - Vectors longer than expected are truncated
    /// - Vectors shorter than expected are zero-padded
    public init(
        vector: [Float],
        keywords: [String] = [],
        labels: [String] = [],
        analysisType: AnalysisType,
        confidence: Float = 0.0,
        analysisTimestamp: Date = Date()
    ) {
        // Gracefully handle dimension mismatches instead of crashing
        if vector.count == Self.dimension {
            self.vector = vector
        } else if vector.count > Self.dimension {
            // Truncate to expected dimension
            self.vector = Array(vector.prefix(Self.dimension))
        } else {
            // Pad with zeros to reach expected dimension
            self.vector = vector + Array(repeating: 0.0, count: Self.dimension - vector.count)
        }
        self.keywords = keywords
        self.labels = labels
        self.analysisType = analysisType
        self.confidence = confidence
        self.analysisTimestamp = analysisTimestamp
    }

    /// Convenience initializer for an empty/zero embedding.
    public init(
        emptyFor type: AnalysisType,
        keywords: [String] = [],
        labels: [String] = [],
        confidence: Float = 0.0,
        analysisTimestamp: Date = Date()
    ) {
        self.vector = Array(repeating: 0.0, count: Self.dimension)
        self.keywords = keywords
        self.labels = labels
        self.analysisType = type
        self.confidence = confidence
        self.analysisTimestamp = analysisTimestamp
    }

    // MARK: - Utilities

    /// Returns true if the underlying vector is all zeros.
    public var isZeroVector: Bool {
        for v in vector { if v != 0.0 { return false } }
        return true
    }

    /// Returns an L2-normalized copy of the embedding vector. If the vector is zero, returns the original vector.
    public var normalizedVector: [Float] {
        var sumSquares: Float = 0.0
        for v in vector { sumSquares += v * v }
        guard sumSquares > 0 else { return vector }
        let invLen = 1.0 / sqrt(sumSquares)
        return vector.map { $0 * invLen }
    }

    /// Compute cosine similarity between this embedding and another embedding.
    /// Returns a Float in range -1.0 ... 1.0. If either vector is zero, returns 0.0.
    public func cosineSimilarity(with other: SemanticEmbedding) -> Float {
        if self.vector.count != other.vector.count { return 0.0 }
        var lhsSum: Float = 0.0
        var rhsSum: Float = 0.0
        var dot: Float = 0.0
        for i in 0..<self.vector.count {
            let a = self.vector[i]
            let b = other.vector[i]
            dot += a * b
            lhsSum += a * a
            rhsSum += b * b
        }
        guard lhsSum > 0, rhsSum > 0 else { return 0.0 }
        return dot / (sqrt(lhsSum) * sqrt(rhsSum))
    }

    /// Short textual summary for logging and debugging.
    public var summary: String {
        let kw = keywords.isEmpty ? "none" : keywords.joined(separator: ", ")
        let lbl = labels.isEmpty ? "none" : labels.joined(separator: ", ")
        let confidenceStr = String(format: "%.2f", confidence)
        return "SemanticEmbedding(type: \(analysisType.rawValue), confidence: \(confidenceStr), keywords: [\(kw)], labels: [\(lbl)])"
    }

    /// Validate dimensions and return true when vector length matches expectations.
    public func isValidDimension() -> Bool {
        vector.count == Self.dimension
    }
}

// MARK: - Convenience factory helpers

public extension SemanticEmbedding {
    /// Create a SemanticEmbedding from an optional vector. If `vector` is nil or wrong-sized,
    /// returns an empty zero-vector embedding of the requested type.
    static func fromSafe(vector: [Float]?, analysisType: AnalysisType, keywords: [String] = [], labels: [String] = [], confidence: Float = 0.0) -> SemanticEmbedding {
        if let v = vector, v.count == Self.dimension {
            return SemanticEmbedding(vector: v, keywords: keywords, labels: labels, analysisType: analysisType, confidence: confidence)
        } else {
            Logger.ml.debug("Received invalid or nil embedding vector; returning zero-vector embedding (expected dimension: \(Self.dimension))")
            return SemanticEmbedding(emptyFor: analysisType, keywords: keywords, labels: labels, confidence: confidence)
        }
    }
}
