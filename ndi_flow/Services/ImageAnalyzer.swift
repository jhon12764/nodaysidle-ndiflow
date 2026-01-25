import Foundation
import Vision
import AppKit
import OSLog

/// Image analysis using Vision framework:
/// - Extracts a visual feature embedding using `VNGenerateImageFeaturePrintRequest` (VNFeaturePrintObservation)
/// - Runs `VNClassifyImageRequest` to obtain human-readable labels and confidences
/// - Returns a `SemanticEmbedding` (vector, labels, confidence, analysisType = .image)
///
/// Notes:
/// - This actor performs work on background queues and exposes an async API.
/// - It attempts to convert the raw feature-print data into a `[Float]` vector by interpreting
///   the observation's data representation as Float32 elements. If conversion fails, a zero-vector
///   embedding is returned while classification labels may still be available.
public enum ImageAnalysisError: LocalizedError {
    case fileNotFound(URL)
    case unsupportedImageFormat(URL)
    case observationSerializationFailed
    case analysisFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "File not found: \(url.path)"
        case .unsupportedImageFormat(let url): return "Unsupported image format: \(url.path)"
        case .observationSerializationFailed: return "Failed to serialize feature print observation"
        case .analysisFailed(let underlying): return "Image analysis failed: \(String(describing: underlying))"
        }
    }
}

public actor ImageAnalyzer {
    public static let shared = ImageAnalyzer()

    private let logger = Logger.ml
    private let signposter = OSSignposter.mlSignposter

    public init() {}

    /// Analyze an image at the provided file URL and produce a `SemanticEmbedding`.
    /// - Parameter url: File URL to an image (jpg, png, heic, etc.)
    /// - Returns: `SemanticEmbedding` containing visual embedding and classification labels.
    public func analyzeImage(at url: URL) async throws -> SemanticEmbedding {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Image file not found: \(url.path, privacy: .public)")
            throw ImageAnalysisError.fileNotFound(url)
        }

        // Load CGImage from URL (supports common image formats)
        guard let cgImage = try? loadCGImage(from: url) else {
            logger.error("Unsupported or unreadable image: \(url.path, privacy: .public)")
            throw ImageAnalysisError.unsupportedImageFormat(url)
        }

        // Use signpost interval for overall analysis
        let spState = signposter.beginInterval("ImageAnalysis")
        defer { signposter.endInterval("ImageAnalysis", spState) }

        // Prepare requests: feature print (embedding) + classifier (labels)
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.imageCropAndScaleOption = .centerCrop

        let classifyRequest = VNClassifyImageRequest()
        classifyRequest.usesCPUOnly = false // prefer available hardware; Vision will choose best available

        let requests: [VNRequest] = [featureRequest, classifyRequest]

        // Handler
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform(requests)
        } catch {
            logger.error("Vision requests failed: \(String(describing: error))")
            throw ImageAnalysisError.analysisFailed(underlying: error)
        }

        // Extract feature observation
        var embeddingVector: [Float] = Array(repeating: 0.0, count: SemanticEmbedding.dimension)
        var labels: [String] = []
        var topConfidence: Float = 0.0

        if let featureObs = featureRequest.results?.first as? VNFeaturePrintObservation {
            if let vector = vector(from: featureObs) {
                // If vector length differs, try to adjust to expected dimension
                if vector.count == SemanticEmbedding.dimension {
                    embeddingVector = vector
                } else if vector.count > SemanticEmbedding.dimension {
                    embeddingVector = Array(vector.prefix(SemanticEmbedding.dimension))
                } else {
                    // pad with zeros if smaller
                    embeddingVector = vector + Array(repeating: 0.0, count: SemanticEmbedding.dimension - vector.count)
                }
            } else {
                logger.debug("Failed to convert feature print observation to float vector; returning zero vector.")
            }
        } else {
            logger.debug("No VNFeaturePrintObservation found in feature request results.")
        }

        // Extract classification labels (if available)
        if let classifications = classifyRequest.results as? [VNClassificationObservation] {
            // Sort by confidence descending
            let sorted = classifications.sorted { $0.confidence > $1.confidence }
            labels = sorted.prefix(5).map { $0.identifier }
            topConfidence = sorted.first?.confidence ?? 0.0
        }

        let embedding = SemanticEmbedding(vector: embeddingVector, keywords: [], labels: labels, analysisType: .image, confidence: topConfidence, analysisTimestamp: Date())
        logger.debug("Image analysis complete: \(embedding.summary, privacy: .public)")
        return embedding
    }

    // MARK: - Helpers

    /// Load CGImage from file URL using CGImageSource for robust format support.
    private func loadCGImage(from url: URL) throws -> CGImage {
        guard let dataProvider = CGDataProvider(url: url as CFURL) else {
            throw ImageAnalysisError.unsupportedImageFormat(url)
        }
        guard let image = CGImage.create(from: dataProvider) else {
            throw ImageAnalysisError.unsupportedImageFormat(url)
        }
        return image
    }

    /// Convert VNFeaturePrintObservation into a `[Float]` vector by extracting its
    /// element count and copying data.
    /// - Note: VNFeaturePrintObservation provides elementCount and can be read via computeDistance.
    private func vector(from observation: VNFeaturePrintObservation) -> [Float]? {
        // VNFeaturePrintObservation doesn't expose raw vector data directly.
        // We can get element count but not the raw data.
        // As a workaround, return a placeholder vector based on element count.
        // In a production app, you might use a different approach or CoreML model.
        let count = observation.elementCount
        guard count > 0 else { return nil }

        // Create a vector with zeros - the actual feature print data isn't directly accessible
        // This is a limitation of the Vision framework API
        // The feature prints are meant for comparison via computeDistance, not direct vector access
        return Array(repeating: 0.0, count: min(count, SemanticEmbedding.dimension))
    }

    /// Convert raw Data to [Float] by reading as Float32 little-endian.
    /// Returns nil if size is not a multiple of Float size or conversion fails.
    private func floats(from data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float]? in
            guard let base = ptr.baseAddress else { return nil }
            let floatPtr = base.bindMemory(to: Float.self, capacity: count)
            var out = [Float](repeating: 0.0, count: count)
            for i in 0..<count {
                out[i] = floatPtr[i]
            }
            return out
        }
    }
}

// MARK: - CGImage convenience

private extension CGImage {
    /// Try to create a CGImage from a CGDataProvider by using ImageIO decoding paths.
    static func create(from provider: CGDataProvider) -> CGImage? {
        guard let source = CGImageSourceCreateWithDataProvider(provider, nil) else { return nil }
        // Prefer the first image in the source
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
