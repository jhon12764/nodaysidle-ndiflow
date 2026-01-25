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
                // If vector length differs, use average pooling to preserve semantic information
                if vector.count == SemanticEmbedding.dimension {
                    embeddingVector = vector
                } else if vector.count > SemanticEmbedding.dimension {
                    // Use average pooling to reduce dimensions while preserving semantic content
                    embeddingVector = reduceVectorByAveragePooling(vector, targetDimension: SemanticEmbedding.dimension)
                    logger.debug("Reduced \(vector.count)-dim image vector to \(SemanticEmbedding.dimension)-dim via average pooling")
                } else {
                    // Pad with zeros if smaller
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
    /// underlying data buffer.
    /// - Note: VNFeaturePrintObservation exposes `data` property (macOS 11+) containing raw feature print.
    private func vector(from observation: VNFeaturePrintObservation) -> [Float]? {
        let count = observation.elementCount
        guard count > 0 else { return nil }

        // VNFeaturePrintObservation.data contains the raw feature print as bytes
        // elementType indicates the data format (typically .float for feature prints)
        let data = observation.data

        switch observation.elementType {
        case .float:
            // Extract Float32 values from the data buffer
            guard let floatVector = floats(from: data) else {
                logger.debug("Failed to convert feature print data to float array")
                return nil
            }
            logger.debug("Extracted \(floatVector.count) floats from feature print observation")
            return floatVector

        case .double:
            // Convert Double values to Float
            guard data.count % MemoryLayout<Double>.size == 0 else { return nil }
            let doubleCount = data.count / MemoryLayout<Double>.size
            let floatVector: [Float] = data.withUnsafeBytes { ptr -> [Float] in
                guard let base = ptr.baseAddress else { return [] }
                let doublePtr = base.bindMemory(to: Double.self, capacity: doubleCount)
                return (0..<doubleCount).map { Float(doublePtr[$0]) }
            }
            logger.debug("Extracted \(floatVector.count) floats (from doubles) from feature print observation")
            return floatVector

        @unknown default:
            logger.warning("Unknown VNFeaturePrintObservation element type: \(String(describing: observation.elementType))")
            return nil
        }
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

    /// Reduce a high-dimensional vector to target dimension using average pooling.
    /// This preserves more semantic information than simple truncation by averaging
    /// groups of consecutive values.
    ///
    /// - Parameters:
    ///   - vector: The source vector (must be larger than targetDimension)
    ///   - targetDimension: The desired output dimension
    /// - Returns: A reduced vector of targetDimension length
    private func reduceVectorByAveragePooling(_ vector: [Float], targetDimension: Int) -> [Float] {
        guard vector.count > targetDimension, targetDimension > 0 else {
            return Array(vector.prefix(targetDimension))
        }

        var result = [Float](repeating: 0.0, count: targetDimension)
        let sourceCount = vector.count
        let poolSize = Float(sourceCount) / Float(targetDimension)

        for i in 0..<targetDimension {
            let startIdx = Int(Float(i) * poolSize)
            let endIdx = min(Int(Float(i + 1) * poolSize), sourceCount)
            let chunkSize = endIdx - startIdx

            if chunkSize > 0 {
                var sum: Float = 0.0
                for j in startIdx..<endIdx {
                    sum += vector[j]
                }
                result[i] = sum / Float(chunkSize)
            }
        }

        return result
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
