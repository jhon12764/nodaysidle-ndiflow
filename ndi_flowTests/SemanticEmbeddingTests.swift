//
//  SemanticEmbeddingTests.swift
//  ndi_flowTests
//
//  Unit tests for SemanticEmbedding value type.
//

import XCTest
@testable import ndi_flow

final class SemanticEmbeddingTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_correctDimension_succeeds() {
        let vector = [Float](repeating: 1.0, count: SemanticEmbedding.dimension)
        let embedding = SemanticEmbedding(
            vector: vector,
            keywords: ["test"],
            labels: ["label"],
            analysisType: .document
        )
        XCTAssertEqual(embedding.vector.count, SemanticEmbedding.dimension)
        XCTAssertEqual(embedding.keywords, ["test"])
        XCTAssertEqual(embedding.labels, ["label"])
        XCTAssertEqual(embedding.analysisType, .document)
    }

    func testInit_vectorTooLong_getsTruncated() {
        let oversizeVector = [Float](repeating: 1.0, count: SemanticEmbedding.dimension + 100)
        let embedding = SemanticEmbedding(
            vector: oversizeVector,
            analysisType: .image
        )
        XCTAssertEqual(embedding.vector.count, SemanticEmbedding.dimension)
    }

    func testInit_vectorTooShort_getsPadded() {
        let undersizeVector = [Float](repeating: 1.0, count: 100)
        let embedding = SemanticEmbedding(
            vector: undersizeVector,
            analysisType: .document
        )
        XCTAssertEqual(embedding.vector.count, SemanticEmbedding.dimension)
        // First 100 should be 1.0, rest should be 0.0
        XCTAssertEqual(embedding.vector[50], 1.0)
        XCTAssertEqual(embedding.vector[SemanticEmbedding.dimension - 1], 0.0)
    }

    func testInit_emptyVector_getsPaddedToZeros() {
        let embedding = SemanticEmbedding(
            vector: [],
            analysisType: .document
        )
        XCTAssertEqual(embedding.vector.count, SemanticEmbedding.dimension)
        XCTAssertTrue(embedding.isZeroVector)
    }

    func testInitEmpty_createsZeroVector() {
        let embedding = SemanticEmbedding(
            emptyFor: .image,
            keywords: ["keyword"],
            labels: ["label"]
        )
        XCTAssertEqual(embedding.vector.count, SemanticEmbedding.dimension)
        XCTAssertTrue(embedding.isZeroVector)
        XCTAssertEqual(embedding.analysisType, .image)
    }

    // MARK: - isZeroVector Tests

    func testIsZeroVector_allZeros_returnsTrue() {
        let embedding = SemanticEmbedding(emptyFor: .document)
        XCTAssertTrue(embedding.isZeroVector)
    }

    func testIsZeroVector_nonZeroVector_returnsFalse() {
        var vector = [Float](repeating: 0.0, count: SemanticEmbedding.dimension)
        vector[0] = 0.001
        let embedding = SemanticEmbedding(vector: vector, analysisType: .document)
        XCTAssertFalse(embedding.isZeroVector)
    }

    // MARK: - Normalized Vector Tests

    func testNormalizedVector_nonZeroVector_hasUnitLength() {
        var vector = [Float](repeating: 0.0, count: SemanticEmbedding.dimension)
        vector[0] = 3.0
        vector[1] = 4.0
        let embedding = SemanticEmbedding(vector: vector, analysisType: .document)

        let normalized = embedding.normalizedVector
        let length = sqrt(normalized.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(length, 1.0, accuracy: 0.0001)
    }

    func testNormalizedVector_zeroVector_returnsOriginal() {
        let embedding = SemanticEmbedding(emptyFor: .document)
        let normalized = embedding.normalizedVector
        XCTAssertEqual(normalized, embedding.vector)
    }

    // MARK: - Cosine Similarity Tests

    func testCosineSimilarity_identicalEmbeddings_returnsOne() {
        let vector = (0..<SemanticEmbedding.dimension).map { Float($0) }
        let a = SemanticEmbedding(vector: vector, analysisType: .document)
        let b = SemanticEmbedding(vector: vector, analysisType: .document)

        let similarity = a.cosineSimilarity(with: b)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_oppositeEmbeddings_returnsNegativeOne() {
        let vector = (0..<SemanticEmbedding.dimension).map { Float($0 + 1) }
        let oppositeVector = vector.map { -$0 }
        let a = SemanticEmbedding(vector: vector, analysisType: .document)
        let b = SemanticEmbedding(vector: oppositeVector, analysisType: .document)

        let similarity = a.cosineSimilarity(with: b)
        XCTAssertEqual(similarity, -1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_zeroVector_returnsZero() {
        let nonZero = SemanticEmbedding(
            vector: [Float](repeating: 1.0, count: SemanticEmbedding.dimension),
            analysisType: .document
        )
        let zero = SemanticEmbedding(emptyFor: .document)

        let similarity = nonZero.cosineSimilarity(with: zero)
        XCTAssertEqual(similarity, 0.0)
    }

    // MARK: - isValidDimension Tests

    func testIsValidDimension_correctDimension_returnsTrue() {
        let embedding = SemanticEmbedding(
            vector: [Float](repeating: 0.0, count: SemanticEmbedding.dimension),
            analysisType: .document
        )
        XCTAssertTrue(embedding.isValidDimension())
    }

    // MARK: - fromSafe Factory Tests

    func testFromSafe_validVector_createsEmbedding() {
        let vector = [Float](repeating: 1.0, count: SemanticEmbedding.dimension)
        let embedding = SemanticEmbedding.fromSafe(
            vector: vector,
            analysisType: .image,
            keywords: ["test"]
        )
        XCTAssertEqual(embedding.vector, vector)
        XCTAssertFalse(embedding.isZeroVector)
    }

    func testFromSafe_nilVector_returnsZeroEmbedding() {
        let embedding = SemanticEmbedding.fromSafe(
            vector: nil,
            analysisType: .document
        )
        XCTAssertTrue(embedding.isZeroVector)
    }

    func testFromSafe_wrongDimension_returnsZeroEmbedding() {
        let wrongSize = [Float](repeating: 1.0, count: 100)
        let embedding = SemanticEmbedding.fromSafe(
            vector: wrongSize,
            analysisType: .document
        )
        XCTAssertTrue(embedding.isZeroVector)
    }

    // MARK: - Summary Tests

    func testSummary_containsExpectedInfo() {
        let embedding = SemanticEmbedding(
            vector: [Float](repeating: 0.5, count: SemanticEmbedding.dimension),
            keywords: ["swift", "code"],
            labels: ["programming"],
            analysisType: .document,
            confidence: 0.85
        )

        let summary = embedding.summary
        XCTAssertTrue(summary.contains("document"))
        XCTAssertTrue(summary.contains("0.85"))
        XCTAssertTrue(summary.contains("swift"))
        XCTAssertTrue(summary.contains("programming"))
    }

    // MARK: - Codable Tests

    func testCodable_roundTrip_preservesData() throws {
        let original = SemanticEmbedding(
            vector: (0..<SemanticEmbedding.dimension).map { Float($0) * 0.01 },
            keywords: ["test", "coding"],
            labels: ["label1"],
            analysisType: .image,
            confidence: 0.9
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SemanticEmbedding.self, from: data)

        XCTAssertEqual(original.vector, decoded.vector)
        XCTAssertEqual(original.keywords, decoded.keywords)
        XCTAssertEqual(original.labels, decoded.labels)
        XCTAssertEqual(original.analysisType, decoded.analysisType)
        XCTAssertEqual(original.confidence, decoded.confidence)
    }

    // MARK: - Equatable/Hashable Tests

    func testEquatable_identicalEmbeddings_areEqual() {
        let vector = [Float](repeating: 0.5, count: SemanticEmbedding.dimension)
        let a = SemanticEmbedding(vector: vector, analysisType: .document)
        let b = SemanticEmbedding(vector: vector, analysisType: .document)
        XCTAssertEqual(a, b)
    }

    func testHashable_canBeUsedInSet() {
        let vector = [Float](repeating: 0.5, count: SemanticEmbedding.dimension)
        let embedding = SemanticEmbedding(vector: vector, analysisType: .document)

        var set = Set<SemanticEmbedding>()
        set.insert(embedding)
        XCTAssertTrue(set.contains(embedding))
    }
}
