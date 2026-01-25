/*
 DocumentEmbeddingGenerator.swift
 ndi_flow

 Implements a DocumentEmbeddingGenerator that uses NaturalLanguage's NLEmbedding
 (sentence embeddings) and NLTagger for keyword extraction.

 Notes:
 - This generator is a lightweight actor wrapper intended for on-device analysis.
 - Embedding model is lazily loaded on first use and cached in memory.
 - Keyword extraction uses NLTagger to extract candidate words (nouns/adjectives/verbs)
   and returns the most frequent terms as keywords.
 - The produced result is a `SemanticEmbedding` (value type defined elsewhere in the project).

 Target: macOS 15+, Swift 6
*/

import Foundation
import NaturalLanguage
import OSLog

/// Error types for document embedding generation.
public enum DocumentEmbeddingError: LocalizedError {
    case modelLoadFailed
    case embeddingGenerationFailed
    case invalidInput
    case unsupportedLanguage

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load the Natural Language embedding model."
        case .embeddingGenerationFailed:
            return "Failed to generate embedding for the provided text."
        case .invalidInput:
            return "Invalid input provided for embedding generation."
        case .unsupportedLanguage:
            return "Unsupported or undetermined language for embedding generation."
        }
    }
}

/// Actor responsible for generating document-level embeddings and extracting keywords.
/// Uses NLEmbedding for sentence-level vectors and NLTagger to extract keywords.
public actor DocumentEmbeddingGenerator {
    public static let shared = DocumentEmbeddingGenerator()

    // Lazily-loaded embedding model
    private var embeddingModel: NLEmbedding?
    private let logger = Logger.ml

    // Preferred embedding dimension (kept in sync with SemanticEmbedding.dimension)
    private let expectedDimension = SemanticEmbedding.dimension

    private init() {
        // Intentionally lightweight; model is loaded lazily in `ensureModelLoaded()`.
    }

    /// Ensure the NLEmbedding model is loaded and usable.
    /// Tries to load the sentence embedding model for the provided language if available.
    private func ensureModelLoaded(preferredLanguage: NLLanguage? = nil) throws {
        if embeddingModel != nil { return }

        // Attempt to load a sentence embedding model. We try to prefer the preferredLanguage
        // if provided, otherwise allow the system to select a suitable default.
        // Per Apple's NaturalLanguage APIs, obtaining a sentence embedding is performed via
        // `NLEmbedding.sentenceEmbedding(for:)`.
        //
        // Note: Loading is lazy and can be relatively expensive; we cache the result.
        do {
            if let lang = preferredLanguage {
                if let model = NLEmbedding.sentenceEmbedding(for: lang) {
                    embeddingModel = model
                    logger.debug("Loaded sentence embedding model for language: \(lang.rawValue, privacy: .public)")
                    return
                } else {
                    logger.debug("No sentence embedding available for requested language: \(lang.rawValue, privacy: .public)")
                }
            }

            // Fallback: try English as a default
            // Note: NLEmbedding.sentenceEmbedding() requires a language parameter

            // Fallback: attempt to load english embedding explicitly
            if let model = NLEmbedding.sentenceEmbedding(for: .english) {
                embeddingModel = model
                logger.debug("Loaded sentence embedding model for English as fallback")
                return
            }

            // If we reach here, we failed to obtain a model
            logger.error("Failed to obtain an NLEmbedding sentence model")
            throw DocumentEmbeddingError.modelLoadFailed
        } catch {
            logger.error("Unexpected error while loading embedding model: \(String(describing: error))")
            throw DocumentEmbeddingError.modelLoadFailed
        }
    }

    /// Generate a `SemanticEmbedding` for the given text.
    ///
    /// - Parameters:
    ///   - text: The textual content to analyze.
    ///   - language: Optional language hint to improve embedding selection (e.g. .english).
    ///   - topKeywords: Number of top keywords to return (default 10).
    /// - Returns: A `SemanticEmbedding` containing vector, keywords, and metadata.
    public func generateEmbedding(fromText text: String, language: NLLanguage? = nil, topKeywords: Int = 10) async throws -> SemanticEmbedding {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.debug("Empty text supplied to generateEmbedding(fromText:); returning zero-vector embedding")
            return SemanticEmbedding(emptyFor: .document, keywords: [], labels: [], confidence: 0.0, analysisTimestamp: Date())
        }

        // Attempt language determination if not provided
        let lang: NLLanguage?
        if let language = language {
            lang = language
        } else {
            // Try to determine language from the text (best-effort)
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(trimmed)
            if let dominant = recognizer.dominantLanguage {
                lang = dominant
                logger.debug("Detected language: \(dominant.rawValue, privacy: .public)")
            } else {
                lang = nil
                logger.debug("Language could not be confidently detected")
            }
        }

        // Ensure embedding model is loaded (prefer detected language)
        try ensureModelLoaded(preferredLanguage: lang)

        guard let model = embeddingModel else {
            throw DocumentEmbeddingError.modelLoadFailed
        }

        // Generate embedding vector using the model.
        // We request a sentence-level embedding for the trimmed text.
        // The NaturalLanguage API returns an optional vector; treat failure gracefully.
        //
        // Note: NLEmbedding.vector(for:) can crash on certain inputs. Our floatVector wrapper
        // sanitizes text to reduce this risk, but we also catch any remaining issues here.
        let vector: [Float]
        let targetDimension = self.expectedDimension

        // Generate embedding - floatVector returns nil on failure (doesn't throw)
        // Input is already sanitized within floatVector to reduce crash risk
        let generatedVector = model.floatVector(for: trimmed)

        if let v = generatedVector, !v.isEmpty {
            // Validate dimension, and adjust if necessary (pad or trim).
            if v.count == targetDimension {
                vector = v
            } else if v.count > targetDimension {
                logger.debug("Embedding vector larger than expected; trimming to \(targetDimension) dims")
                vector = Array(v.prefix(targetDimension))
            } else {
                // If smaller, pad with zeros to expected dimension
                logger.debug("Embedding vector smaller than expected; padding to \(targetDimension) dims")
                var padded = v
                padded.append(contentsOf: Array(repeating: 0.0, count: targetDimension - v.count))
                vector = padded
            }
        } else {
            // If embedding generation fails, return a zero-vector with extracted keywords
            // This allows the file to still be indexed without crashing
            logger.warning("NLEmbedding returned nil for provided text; using zero vector")
            let keywords = extractKeywords(from: trimmed, maxKeywords: topKeywords)
            return SemanticEmbedding(
                emptyFor: .document,
                keywords: keywords,
                labels: [],
                confidence: 0.0,
                analysisTimestamp: Date()
            )
        }

        // Extract keywords using NLTagger
        let keywords = extractKeywords(from: trimmed, maxKeywords: topKeywords)

        // Heuristic confidence: use mean absolute value of vector as a simple proxy (not a substitute for model confidence)
        let confidence = computeConfidence(from: vector)

        let embedding = SemanticEmbedding(vector: vector, keywords: keywords, labels: [], analysisType: .document, confidence: confidence, analysisTimestamp: Date())
        logger.debug("Generated embedding: \(embedding.summary, privacy: .public)")
        return embedding
    }

    // MARK: - Keyword extraction

    /// Extract top-K keywords from text using NLTagger.
    /// This function favors nouns/adjectives/verbs and counts frequency of normalized tokens.
    private func extractKeywords(from text: String, maxKeywords: Int) -> [String] {
        guard !text.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text

        var frequency: [String: Int] = [:]
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
        let desiredTags: Set<NLTag> = [.noun, .adjective, .verb]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            guard let tag = tag, desiredTags.contains(tag) else { return true }
            let token = String(text[tokenRange]).lowercased()

            // Try to use lemma if available for normalization
            let (lemmaTag, _) = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma)
            if let lemmaValue = lemmaTag?.rawValue.lowercased(), lemmaValue.count > 1 {
                frequency[lemmaValue, default: 0] += 1
            } else if token.count > 1 {
                frequency[token, default: 0] += 1
            } else {
                // Basic normalization: strip punctuation, short tokens filtered
                let normalized = token.trimmingCharacters(in: .punctuationCharacters)
                if normalized.count > 1 {
                    frequency[normalized, default: 0] += 1
                }
            }
            return true
        }

        // Sort tokens by frequency then by length and return top maxKeywords
        let sorted = frequency.keys.sorted { (a, b) -> Bool in
            let fa = frequency[a] ?? 0
            let fb = frequency[b] ?? 0
            if fa != fb { return fa > fb }
            return a.count > b.count
        }
        let top = sorted.prefix(maxKeywords).map { String($0) }
        return Array(top)
    }

    // MARK: - Utility heuristics

    /// Compute a simple confidence heuristic for an embedding vector.
    /// Returns value in 0.0 ... 1.0.
    private func computeConfidence(from vector: [Float]) -> Float {
        // Use normalized RMS as a lightweight proxy (not a true model confidence).
        guard !vector.isEmpty else { return 0.0 }
        var sumSquares: Float = 0.0
        for v in vector { sumSquares += v * v }
        let rms = sqrt(sumSquares / Float(vector.count))
        // Map RMS -> (0..1) using a mild scaling factor and clamp.
        let scaled = min(max(rms * 2.0, 0.0), 1.0)
        return scaled
    }
}

// MARK: - Convenience extensions for NLEmbedding interop

private extension NLEmbedding {
    /// Attempt to return a Float vector for the supplied text. Returns nil if the embedding could not be produced.
    /// This wrapper normalizes the raw embedding type to `[Float]` expected by our pipeline.
    ///
    /// Note: NLEmbedding.vector(for:) can crash (abort) on certain malformed or problematic text inputs.
    /// We sanitize the input and use defensive programming to minimize crash risk.
    func floatVector(for text: String) -> [Float]? {
        // Sanitize text to reduce crash risk from problematic characters
        let sanitized = sanitizeTextForEmbedding(text)
        guard !sanitized.isEmpty else {
            return nil
        }

        // NLEmbedding.vector(for:) returns [Double]? on macOS 15+
        // This call can abort on certain inputs - we've sanitized to reduce risk
        guard let raw = self.vector(for: sanitized) else {
            return nil
        }

        // Convert [Double] to [Float] safely
        var out: [Float] = []
        out.reserveCapacity(raw.count)
        for d in raw {
            // Guard against NaN/Inf values that could cause issues downstream
            let f = Float(d)
            if f.isNaN || f.isInfinite {
                out.append(0.0)
            } else {
                out.append(f)
            }
        }
        return out
    }

    /// Sanitize text input to reduce risk of NLEmbedding crashes.
    /// Removes problematic characters and limits text length.
    private func sanitizeTextForEmbedding(_ text: String) -> String {
        // Limit text length - very long texts can cause issues
        let maxLength = 50000
        var sanitized = text.count > maxLength ? String(text.prefix(maxLength)) : text

        // Remove null characters and other control characters that can cause crashes
        sanitized = sanitized.unicodeScalars.filter { scalar in
            // Keep printable characters, newlines, tabs, and most unicode
            // Exclude null, control characters (except newline/tab), and private use area
            if scalar.value == 0 { return false } // null
            if scalar.value < 32 && scalar.value != 9 && scalar.value != 10 && scalar.value != 13 { return false } // control chars
            if scalar.value >= 0xE000 && scalar.value <= 0xF8FF { return false } // private use area
            if scalar.value >= 0xFFF0 && scalar.value <= 0xFFFF { return false } // specials
            return true
        }.map { Character($0) }.reduce(into: "") { $0.append($1) }

        // Ensure we have actual content after sanitization
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        // If text is too short after sanitization, it may not produce meaningful embeddings
        guard trimmed.count >= 3 else {
            return ""
        }

        return trimmed
    }
}
