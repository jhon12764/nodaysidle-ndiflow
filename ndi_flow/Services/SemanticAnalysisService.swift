/*
 SemanticAnalysisService.swift
 ndi_flow

 Actor that coordinates document and image semantic analysis by wiring
 DocumentEmbeddingGenerator and ImageAnalyzer. Provides domain-specific
 errors, in-memory caching, timeout protection, and os_signpost instrumentation.

 Responsibilities:
 - analyzeDocument(_:): extracts text, generates document embedding, extracts keywords
 - analyzeImage(_:): generates visual embedding and labels
 - Caches recent embeddings keyed by file URL + modification date
 - Uses a simple timeout guard for long-running analyses

 Target: macOS 15+, Swift 6
*/

import Foundation
import OSLog
import UniformTypeIdentifiers

// Domain errors aligned with TRD contracts
public enum SemanticAnalysisError: LocalizedError, Sendable {
    case fileNotFound(URL)
    case unsupportedFormat(URL)
    case mlModelLoadError(underlying: Error?)
    case analysisTimeout(URL)
    case analysisFailed(URL, underlying: Error?)
    case accessDenied(URL)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found at path: \(url.path)"
        case .unsupportedFormat(let url):
            return "Unsupported format for file: \(url.path)"
        case .mlModelLoadError(let underlying):
            return "Failed to load ML model. \(String(describing: underlying))"
        case .analysisTimeout(let url):
            return "Analysis timed out for file: \(url.path)"
        case .analysisFailed(let url, let underlying):
            return "Analysis failed for file: \(url.path). \(String(describing: underlying))"
        case .accessDenied(let url):
            return "Access denied to file: \(url.path)"
        }
    }
}

/// SemanticAnalysisService actor - coordinates document & image analysis
public actor SemanticAnalysisService {
    public static let shared = SemanticAnalysisService()

    // Simple in-memory cache keyed by "path|modDate.timeIntervalSince1970"
    // Stored as [String: (embedding: SemanticEmbedding, timestamp: Date)]
    private var cache: [String: (embedding: SemanticEmbedding, storedAt: Date)] = [:]

    // Default per-file analysis timeout (seconds)
    private let analysisTimeoutSeconds: TimeInterval = 30.0

    // Logger and signposter
    private let logger = Logger.ml
    private let signposter = OSSignposter.mlSignposter

    public init() {}

    // MARK: - Public API

    /// Analyze a document at the given URL and return a SemanticEmbedding.
    /// - Throws: SemanticAnalysisError on failure.
    public func analyzeDocument(_ url: URL) async throws -> SemanticEmbedding {
        // Validate file existence
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Document not found: \(url.path, privacy: .public)")
            throw SemanticAnalysisError.fileNotFound(url)
        }

        // Check read access
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            logger.error("Document access denied: \(url.path, privacy: .public)")
            throw SemanticAnalysisError.accessDenied(url)
        }

        // Obtain modification date for cache key
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let key = cacheKey(for: url, modifiedDate: modDate)

        // Return cached embedding if present
        if let cached = cache[key] {
            logger.debug("Document embedding cache hit: \(url.path, privacy: .public)")
            return cached.embedding
        }

        // Signpost start
        let spState = signposter.beginInterval("DocumentAnalysis")
        logger.log("Starting document analysis for \(url.path, privacy: .public)")

        do {
            // Extract text (may throw)
            let text = try await DocumentTextExtractor.extractText(from: url)

            // If no text extracted, return zero/placeholder embedding
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.debug("No text extracted from document: \(url.path, privacy: .public). Returning empty embedding.")
                let empty = SemanticEmbedding.emptyFor(type: .document, keywords: [], labels: [], confidence: 0.0, analysisTimestamp: Date())
                cache[key] = (embedding: empty, storedAt: Date())
                signposter.endInterval("DocumentAnalysis", spState)
                return empty
            }

            // Run embedding generation with timeout protection
            let embedding = try await withTimeout(seconds: analysisTimeoutSeconds, url: url) {
                try await DocumentEmbeddingGenerator.shared.generateEmbedding(fromText: text, language: nil, topKeywords: 10)
            }

            // Cache embedding
            cache[key] = (embedding: embedding, storedAt: Date())
            logger.log("Document analysis complete for \(url.path, privacy: .public)")

            // End signpost
            signposter.endInterval("DocumentAnalysis", spState)
            return embedding
        } catch let err as SemanticAnalysisError {
            signposter.endInterval("DocumentAnalysis", spState)
            logger.error("SemanticAnalysisError during document analysis: \(String(describing: err))")
            throw err
        } catch {
            signposter.endInterval("DocumentAnalysis", spState)
            logger.error("Unexpected error during document analysis: \(String(describing: error))")
            throw SemanticAnalysisError.analysisFailed(url, underlying: error)
        }
    }

    /// Analyze an image at the given URL and return a SemanticEmbedding (visual vector + labels).
    /// - Throws: SemanticAnalysisError on failure.
    public func analyzeImage(_ url: URL) async throws -> SemanticEmbedding {
        // Validate file existence
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Image not found: \(url.path, privacy: .public)")
            throw SemanticAnalysisError.fileNotFound(url)
        }

        // Check read access
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            logger.error("Image access denied: \(url.path, privacy: .public)")
            throw SemanticAnalysisError.accessDenied(url)
        }

        // Quick UTType check (best-effort)
        if let ut = UTType(filenameExtension: url.pathExtension), !(ut.conforms(to: .image)) {
            logger.debug("File does not appear to be an image: \(url.path, privacy: .public)")
            // We won't immediately fail; ImageAnalyzer may still attempt to process, but surface unsupported format if it does.
        }

        // Obtain modification date for cache key
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let key = cacheKey(for: url, modifiedDate: modDate)

        // Return cached embedding if present
        if let cached = cache[key] {
            logger.debug("Image embedding cache hit: \(url.path, privacy: .public)")
            return cached.embedding
        }

        // Signpost start
        let spState = signposter.beginInterval("ImageAnalysis")
        logger.log("Starting image analysis for \(url.path, privacy: .public)")

        do {
            // Run image analyzer with timeout protection
            let embedding = try await withTimeout(seconds: analysisTimeoutSeconds, url: url) {
                try await ImageAnalyzer.shared.analyzeImage(at: url)
            }

            // Cache embedding
            cache[key] = (embedding: embedding, storedAt: Date())
            logger.log("Image analysis complete for \(url.path, privacy: .public)")

            signposter.endInterval("ImageAnalysis", spState)
            return embedding
        } catch let err as SemanticAnalysisError {
            signposter.endInterval("ImageAnalysis", spState)
            logger.error("SemanticAnalysisError during image analysis: \(String(describing: err))")
            throw err
        } catch {
            signposter.endInterval("ImageAnalysis", spState)
            logger.error("Unexpected error during image analysis: \(String(describing: error))")
            throw SemanticAnalysisError.analysisFailed(url, underlying: error)
        }
    }

    // MARK: - Cache management

    /// Clears the in-memory analysis cache.
    public func clearCache() {
        cache.removeAll()
        logger.log("Semantic analysis cache cleared.")
    }

    /// Remove cache entry for a specific file (useful on file deletion/rename)
    public func invalidateCache(for url: URL) async {
        // Use a best-effort approach: remove any key that starts with the file path
        let prefix = url.path + "|"
        let keysToRemove = cache.keys.filter { $0.hasPrefix(prefix) }
        for k in keysToRemove { cache.removeValue(forKey: k) }
        logger.debug("Invalidated cache entries for \(url.path, privacy: .public)")
    }

    // MARK: - Helpers

    /// Build a stable cache key from file URL and modification date
    private func cacheKey(for url: URL, modifiedDate: Date) -> String {
        return "\(url.path)|\(modifiedDate.timeIntervalSince1970)"
    }

    /// Timeout wrapper: runs `operation` and races it against a sleep that will throw analysisTimeout.
    /// Uses a Throwing TaskGroup to allow cancellation of the slower task.
    private func withTimeout<T: Sendable>(seconds: TimeInterval, url: URL, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SemanticAnalysisError.analysisTimeout(url)
            }
            // Wait for the first successful result or throw
            let result = try await group.next()!
            // Cancel remaining tasks
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Convenience extensions for SemanticEmbedding construction
private extension SemanticEmbedding {
    static func emptyFor(type: AnalysisType, keywords: [String] = [], labels: [String] = [], confidence: Float = 0.0, analysisTimestamp: Date = Date()) -> SemanticEmbedding {
        return SemanticEmbedding(vector: Array(repeating: 0.0, count: SemanticEmbedding.dimension), keywords: keywords, labels: labels, analysisType: type, confidence: confidence, analysisTimestamp: analysisTimestamp)
    }
}
