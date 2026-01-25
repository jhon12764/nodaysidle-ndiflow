//
//  VectorMathTests.swift
//  ndi_flowTests
//
//  Unit tests for VectorMath utilities.
//

import XCTest
@testable import ndi_flow

final class VectorMathTests: XCTestCase {

    // MARK: - Dot Product Tests

    func testDotProduct_sameVectors_returnsSquaredNorm() {
        let v = [1.0, 2.0, 3.0] as [Float]
        let result = VectorMath.dot(v, v)
        XCTAssertEqual(result, 14.0, accuracy: 0.0001) // 1 + 4 + 9 = 14
    }

    func testDotProduct_orthogonalVectors_returnsZero() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let result = VectorMath.dot(a, b)
        XCTAssertEqual(result, 0.0, accuracy: 0.0001)
    }

    func testDotProduct_differentLengths_returnsZero() {
        let a: [Float] = [1.0, 2.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        let result = VectorMath.dot(a, b)
        XCTAssertEqual(result, 0.0)
    }

    func testDotProduct_emptyVectors_returnsZero() {
        let result = VectorMath.dot([], [])
        XCTAssertEqual(result, 0.0)
    }

    // MARK: - Sum of Squares Tests

    func testSumOfSquares_standardVector() {
        let v: [Float] = [3.0, 4.0]
        let result = VectorMath.sumOfSquares(v)
        XCTAssertEqual(result, 25.0, accuracy: 0.0001) // 9 + 16 = 25
    }

    func testSumOfSquares_emptyVector_returnsZero() {
        let result = VectorMath.sumOfSquares([])
        XCTAssertEqual(result, 0.0)
    }

    // MARK: - L2 Norm Tests

    func testL2Norm_standardVector() {
        let v: [Float] = [3.0, 4.0]
        let result = VectorMath.l2Norm(v)
        XCTAssertEqual(result, 5.0, accuracy: 0.0001) // sqrt(25) = 5
    }

    func testL2Norm_zeroVector_returnsZero() {
        let v: [Float] = [0.0, 0.0, 0.0]
        let result = VectorMath.l2Norm(v)
        XCTAssertEqual(result, 0.0)
    }

    // MARK: - Normalize Tests

    func testNormalize_standardVector_returnsUnitVector() {
        let v: [Float] = [3.0, 4.0]
        let result = VectorMath.normalize(v)
        XCTAssertEqual(result[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.8, accuracy: 0.0001)

        // Verify it's a unit vector
        let norm = VectorMath.l2Norm(result)
        XCTAssertEqual(norm, 1.0, accuracy: 0.0001)
    }

    func testNormalize_zeroVector_returnsOriginal() {
        let v: [Float] = [0.0, 0.0]
        let result = VectorMath.normalize(v)
        XCTAssertEqual(result, v)
    }

    func testNormalize_emptyVector_returnsEmpty() {
        let result = VectorMath.normalize([])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Cosine Similarity Tests

    func testCosineSimilarity_identicalVectors_returnsOne() {
        let v: [Float] = [1.0, 2.0, 3.0]
        let result = VectorMath.cosineSimilarity(v, v)
        XCTAssertEqual(result, 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_oppositeVectors_returnsNegativeOne() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        let result = VectorMath.cosineSimilarity(a, b)
        XCTAssertEqual(result, -1.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_orthogonalVectors_returnsZero() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        let result = VectorMath.cosineSimilarity(a, b)
        XCTAssertEqual(result, 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarity_differentLengths_returnsZero() {
        let a: [Float] = [1.0, 2.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        let result = VectorMath.cosineSimilarity(a, b)
        XCTAssertEqual(result, 0.0)
    }

    func testCosineSimilarity_zeroVector_returnsZero() {
        let a: [Float] = [1.0, 2.0]
        let b: [Float] = [0.0, 0.0]
        let result = VectorMath.cosineSimilarity(a, b)
        XCTAssertEqual(result, 0.0)
    }

    func testCosineSimilarity_scaledVectors_returnsSameResult() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [2.0, 4.0, 6.0] // Same direction, different magnitude
        let result = VectorMath.cosineSimilarity(a, b)
        XCTAssertEqual(result, 1.0, accuracy: 0.0001)
    }

    // MARK: - Cosine Similarity Normalized Tests

    func testCosineSimilarityNormalized_preNormalizedVectors() {
        let a = VectorMath.normalize([1.0, 2.0, 3.0])
        let b = VectorMath.normalize([1.0, 2.0, 3.0])
        let result = VectorMath.cosineSimilarityNormalized(a, b)
        XCTAssertEqual(result, 1.0, accuracy: 0.0001)
    }

    // MARK: - Average Tests

    func testAverage_multipleVectors_returnsCorrectCentroid() {
        let vectors: [[Float]] = [
            [1.0, 2.0, 3.0],
            [3.0, 4.0, 5.0],
            [5.0, 6.0, 7.0]
        ]
        let result = VectorMath.average(of: vectors)
        XCTAssertNotNil(result)
        XCTAssertEqual(result![0], 3.0, accuracy: 0.0001)
        XCTAssertEqual(result![1], 4.0, accuracy: 0.0001)
        XCTAssertEqual(result![2], 5.0, accuracy: 0.0001)
    }

    func testAverage_emptyArray_returnsNil() {
        let result = VectorMath.average(of: [])
        XCTAssertNil(result)
    }

    func testAverage_mismatchedDimensions_returnsNil() {
        let vectors: [[Float]] = [
            [1.0, 2.0],
            [1.0, 2.0, 3.0]
        ]
        let result = VectorMath.average(of: vectors)
        XCTAssertNil(result)
    }

    // MARK: - Batch Cosine Similarity Tests

    func testBatchCosineSimilarity_multiplesCandidates() {
        let query: [Float] = [1.0, 0.0]
        let candidates: [[Float]] = [
            [1.0, 0.0],  // identical
            [0.0, 1.0],  // orthogonal
            [-1.0, 0.0]  // opposite
        ]
        let results = VectorMath.batchCosineSimilarity(query: query, candidates: candidates)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(results[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(results[2], -1.0, accuracy: 0.0001)
    }

    func testBatchCosineSimilarity_emptyQuery_returnsZeros() {
        let candidates: [[Float]] = [[1.0, 2.0], [3.0, 4.0]]
        let results = VectorMath.batchCosineSimilarity(query: [], candidates: candidates)
        XCTAssertEqual(results, [0.0, 0.0])
    }

    // MARK: - Performance Tests

    func testPerformance_cosineSimilarity_largeVectors() {
        let dim = 512
        let a = (0..<dim).map { _ in Float.random(in: -1...1) }
        let b = (0..<dim).map { _ in Float.random(in: -1...1) }

        measure {
            for _ in 0..<1000 {
                _ = VectorMath.cosineSimilarity(a, b)
            }
        }
    }

    func testPerformance_batchCosineSimilarity() {
        let dim = 512
        let query = (0..<dim).map { _ in Float.random(in: -1...1) }
        let candidates = (0..<100).map { _ in
            (0..<dim).map { _ in Float.random(in: -1...1) }
        }

        measure {
            _ = VectorMath.batchCosineSimilarity(query: query, candidates: candidates)
        }
    }
}
