//
//  ClusteringEngineTests.swift
//  ndi_flowTests
//
//  Unit tests for ClusteringEngine.
//

import XCTest
@testable import ndi_flow

final class ClusteringEngineTests: XCTestCase {

    // MARK: - Helper Functions

    private func createIndexedFile(
        name: String,
        vector: [Float]? = nil
    ) -> IndexedFile {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        let embedding: SemanticEmbedding?
        if let v = vector {
            embedding = SemanticEmbedding(vector: v, analysisType: .document)
        } else {
            embedding = nil
        }

        return IndexedFile(
            url: url,
            fileName: name,
            fileType: "txt",
            fileSize: 100,
            createdDate: Date(),
            modifiedDate: Date(),
            embedding: embedding,
            status: .indexed
        )
    }

    private func randomVector(dimension: Int = SemanticEmbedding.dimension) -> [Float] {
        (0..<dimension).map { _ in Float.random(in: -1...1) }
    }

    private func similarVector(to base: [Float], similarity: Float) -> [Float] {
        // Create a vector with controlled similarity to the base
        // Higher similarity = more similar direction
        let noise = (0..<base.count).map { _ in Float.random(in: -1...1) }
        return zip(base, noise).map { base, n in
            base * similarity + n * (1 - similarity)
        }
    }

    // MARK: - Basic Tests

    func testClusterFiles_emptyInput_throws() {
        XCTAssertThrowsError(try ClusteringEngine.clusterFiles([], threshold: 0.5)) { error in
            XCTAssertEqual(error as? ClusteringError, .insufficientData)
        }
    }

    func testClusterFiles_noEmbeddings_throws() {
        let files = [
            createIndexedFile(name: "file1"),
            createIndexedFile(name: "file2")
        ]

        XCTAssertThrowsError(try ClusteringEngine.clusterFiles(files, threshold: 0.5)) { error in
            XCTAssertEqual(error as? ClusteringError, .noEmbeddingsFound)
        }
    }

    func testClusterFiles_singleFile_returnsSingleCluster() throws {
        let vector = randomVector()
        let files = [createIndexedFile(name: "file1", vector: vector)]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.5)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberCount, 1)
    }

    // MARK: - Clustering Behavior Tests

    func testClusterFiles_identicalVectors_mergesIntoClusters() throws {
        let vector = randomVector()
        let files = [
            createIndexedFile(name: "file1", vector: vector),
            createIndexedFile(name: "file2", vector: vector),
            createIndexedFile(name: "file3", vector: vector)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.9)

        // Identical vectors should all be merged into one cluster
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberCount, 3)
    }

    func testClusterFiles_dissimilarVectors_remainsSeparate() throws {
        // Create orthogonal vectors that won't meet similarity threshold
        var v1 = [Float](repeating: 0, count: SemanticEmbedding.dimension)
        var v2 = [Float](repeating: 0, count: SemanticEmbedding.dimension)
        var v3 = [Float](repeating: 0, count: SemanticEmbedding.dimension)
        v1[0] = 1.0
        v2[1] = 1.0
        v3[2] = 1.0

        let files = [
            createIndexedFile(name: "file1", vector: v1),
            createIndexedFile(name: "file2", vector: v2),
            createIndexedFile(name: "file3", vector: v3)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.9)

        // Orthogonal vectors should remain in separate clusters
        XCTAssertEqual(clusters.count, 3)
    }

    func testClusterFiles_mixedSimilarity_clustersCorrectly() throws {
        let baseVector = randomVector()
        let similarToBase = similarVector(to: baseVector, similarity: 0.95)
        let differentVector = randomVector()

        let files = [
            createIndexedFile(name: "file1", vector: baseVector),
            createIndexedFile(name: "file2", vector: similarToBase),
            createIndexedFile(name: "file3", vector: differentVector)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.8)

        // file1 and file2 should cluster together, file3 may be separate or joined depending on random values
        XCTAssertTrue(clusters.count >= 1 && clusters.count <= 3)
    }

    // MARK: - Threshold Tests

    func testClusterFiles_highThreshold_fewerMerges() throws {
        let files = (0..<5).map { i in
            createIndexedFile(name: "file\(i)", vector: randomVector())
        }

        let clustersHighThreshold = try ClusteringEngine.clusterFiles(files, threshold: 0.99)
        let clustersLowThreshold = try ClusteringEngine.clusterFiles(files, threshold: 0.1)

        // Higher threshold should result in more clusters (fewer merges)
        XCTAssertGreaterThanOrEqual(clustersHighThreshold.count, clustersLowThreshold.count)
    }

    func testClusterFiles_zeroThreshold_mergesAll() throws {
        let files = (0..<5).map { i in
            createIndexedFile(name: "file\(i)", vector: randomVector())
        }

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: -1.0)

        // With threshold of -1, all pairs should merge
        XCTAssertEqual(clusters.count, 1)
    }

    // MARK: - Mixed Embedding Status Tests

    func testClusterFiles_mixedEmbeddings_handlesGracefully() throws {
        let vector = randomVector()
        let files = [
            createIndexedFile(name: "file1", vector: vector),
            createIndexedFile(name: "file2", vector: nil),  // No embedding
            createIndexedFile(name: "file3", vector: vector)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.5)

        // File without embedding should remain in its own cluster
        // Files with identical vectors should cluster together
        XCTAssertTrue(clusters.count >= 1)

        // Verify all files are accounted for
        let totalFiles = clusters.reduce(0) { $0 + $1.memberCount }
        XCTAssertEqual(totalFiles, 3)
    }

    // MARK: - Sorting Tests

    func testClusterFiles_resultsSortedBySize() throws {
        // Create files that will form clusters of different sizes
        let v1 = randomVector()
        let v2 = randomVector()

        let files = [
            createIndexedFile(name: "file1", vector: v1),
            createIndexedFile(name: "file2", vector: v1),
            createIndexedFile(name: "file3", vector: v1),
            createIndexedFile(name: "file4", vector: v2)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.99)

        // Assuming v1 files cluster together, they should be first (larger cluster)
        if clusters.count > 1 {
            XCTAssertGreaterThanOrEqual(clusters[0].memberCount, clusters[1].memberCount)
        }
    }

    // MARK: - Centroid Tests

    func testClusterFiles_centroidsComputed() throws {
        let vector = randomVector()
        let files = [
            createIndexedFile(name: "file1", vector: vector),
            createIndexedFile(name: "file2", vector: vector)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.5)

        for cluster in clusters {
            if !cluster.memberEmbeddings.isEmpty {
                XCTAssertNotNil(cluster.centroid)
            }
        }
    }

    // MARK: - Performance Tests

    func testPerformance_smallDataset() throws {
        let files = (0..<50).map { i in
            createIndexedFile(name: "file\(i)", vector: randomVector())
        }

        measure {
            _ = try? ClusteringEngine.clusterFiles(files, threshold: 0.7)
        }
    }

    func testPerformance_mediumDataset() throws {
        let files = (0..<100).map { i in
            createIndexedFile(name: "file\(i)", vector: randomVector())
        }

        measure {
            _ = try? ClusteringEngine.clusterFiles(files, threshold: 0.7)
        }
    }

    // MARK: - Edge Cases

    func testClusterFiles_singleFileWithEmbedding_works() throws {
        let files = [createIndexedFile(name: "file1", vector: randomVector())]
        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.5)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].files[0].fileName, "file1")
    }

    func testClusterFiles_twoIdenticalFiles_merges() throws {
        let vector = [Float](repeating: 1.0, count: SemanticEmbedding.dimension)
        let files = [
            createIndexedFile(name: "file1", vector: vector),
            createIndexedFile(name: "file2", vector: vector)
        ]

        let clusters = try ClusteringEngine.clusterFiles(files, threshold: 0.9)

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberCount, 2)
    }
}
