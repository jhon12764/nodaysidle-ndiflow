//
//  EmbeddingEntity.swift
//  ndi_flow
//
//  SwiftData @Model representing semantic embeddings extracted from files.
//  Stores a fixed-dimension float vector (expected 512), extracted keywords,
//  and the timestamp when analysis was performed. Linked from FileEntity.
//
//  Notes:
//  - The model expects embedding vectors to match `EmbeddingEntity.dimension`.
//  - Basic utility methods are provided for normalization and cosine similarity.
//  - Designed for local on-device semantic analysis storage with SwiftData.
//
//  Target: macOS 15+, Swift 6, SwiftData
//

import Foundation
import SwiftData

@Model
final class EmbeddingEntity: Identifiable {
    // Primary identifier
    var id: UUID

    // Dense embedding vector produced by ML (expected length defined by `dimension`)
    // Using a plain [Float] to store the vector in SwiftData model.
    var vector: [Float]

    // Extracted keywords from the document/image
    var keywords: [String]

    // When the embedding/analysis was produced
    var analysisTimestamp: Date

    // Expected embedding dimension (configurable across app, default 512)
    static let dimension: Int = 512

    // Note: The inverse relationship to FileEntity is NOT declared here.
    // Navigate from FileEntity.embedding instead. This avoids SwiftData
    // initialization issues with bidirectional relationships.

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        vector: [Float],
        keywords: [String] = [],
        analysisTimestamp: Date = Date()
    ) {
        precondition(vector.count == Self.dimension, "Embedding vector must be exactly \(Self.dimension) elements.")
        self.id = id
        self.vector = vector
        self.keywords = keywords
        self.analysisTimestamp = analysisTimestamp
    }

    // Convenience initializer to create a zero-vector embedding (useful as placeholder)
    convenience init(emptyWithKeywords keywords: [String] = []) {
        self.init(vector: Array(repeating: 0.0, count: Self.dimension), keywords: keywords, analysisTimestamp: Date())
    }

    // MARK: - Utilities

    // Returns a normalized copy of the embedding vector (L2 normalization).
    // If the vector is all zeros, the original vector is returned.
    var normalizedVector: [Float] {
        let sumSquares = vector.reduce(0.0) { $0 + $1 * $1 }
        guard sumSquares > 0 else { return vector }
        let invLen = 1.0 / Float(sqrt(sumSquares))
        return vector.map { $0 * invLen }
    }

    // Compute cosine similarity between this embedding and another embedding.
    // Returns a Float in the range -1...1. If either vector is zero-length, returns 0.
    func cosineSimilarity(with other: EmbeddingEntity) -> Float {
        // Fast path: if either vector is zero, similarity is undefined -> return 0
        let lhsSumSquares = vector.reduce(0.0) { $0 + $1 * $1 }
        let rhsSumSquares = other.vector.reduce(0.0) { $0 + $1 * $1 }
        guard lhsSumSquares > 0, rhsSumSquares > 0 else { return 0.0 }

        let dot = zip(vector, other.vector).reduce(0.0) { $0 + $1.0 * $1.1 }
        let denom = Float(sqrt(lhsSumSquares) * sqrt(rhsSumSquares))
        guard denom != 0 else { return 0.0 }
        return dot / denom
    }

    // Update the embedding vector safely (validates dimension)
    func updateVector(_ newVector: [Float]) {
        precondition(newVector.count == Self.dimension, "Embedding vector must be exactly \(Self.dimension) elements.")
        self.vector = newVector
        self.analysisTimestamp = Date()
    }

    // Lightweight description for debugging/logging
    var summary: String {
        let kw = keywords.isEmpty ? "none" : keywords.joined(separator: ", ")
        return "EmbeddingEntity(id: \(id.uuidString), keywords: [\(kw)], timestamp: \(analysisTimestamp))"
    }
}
