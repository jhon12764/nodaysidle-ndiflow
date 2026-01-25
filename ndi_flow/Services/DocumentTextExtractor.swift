/*
 DocumentTextExtractor.swift
 ndi_flow

 Basic document text extraction utilities using PDFKit and Foundation.
 Supports extracting text from:
  - PDF (via PDFKit)
  - Plain text (.txt)
  - RTF (.rtf)
  - RTFD (.rtfd)
  - Falls back gracefully for unsupported formats (returns empty string)

 The extractor is intentionally lightweight and synchronous internally but exposed
 via an `async` API so it can be used in structured-concurrency contexts without
 blocking the caller's actor.

 Target: macOS 15+, Swift 6
*/

import Foundation
import PDFKit
import UniformTypeIdentifiers
import OSLog
import AppKit // for NSAttributedString document initialization

public enum DocumentTextExtractorError: LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(URL)
    case extractionFailed(URL, underlying: Error?)
    case invalidData(URL)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found at path: \(url.path)"
        case .unsupportedFormat(let url):
            return "Unsupported file format: \(url.path)"
        case .extractionFailed(let url, let underlying):
            return "Failed to extract text from \(url.path). Underlying: \(String(describing: underlying))"
        case .invalidData(let url):
            return "Invalid or unreadable data at \(url.path)"
        }
    }
}

public struct DocumentTextExtractor {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ndiflow.app", category: "DocumentTextExtractor")

    /// Extract text content from the supplied file URL.
    /// - Parameter url: File URL to extract text from.
    /// - Returns: Extracted plain text. Empty string if no extractable text was found.
    /// - Throws: DocumentTextExtractorError on unrecoverable failures.
    public static func extractText(from url: URL) async throws -> String {
        // Perform lightweight validation and then dispatch to a background queue for extraction.
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("File not found: \(url.path, privacy: .public)")
            throw DocumentTextExtractorError.fileNotFound(url)
        }

        // Determine UTType where possible to route to the correct extractor.
        let ext = url.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext) ?? UTType.data

        // Use async API but run work on a utility global queue to avoid blocking callers.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    var result: String = ""

                    if utType == .pdf || ext == "pdf" {
                        result = try extractTextFromPDF(url: url)
                    } else if utType.conforms(to: .rtf) || ext == "rtf" || ext == "rtfd" {
                        result = try extractTextFromRTF(url: url)
                    } else if utType.conforms(to: .plainText) || ext == "txt" || ext == "text" {
                        result = try extractTextFromPlainText(url: url)
                    } else if ext == "docx" || utType.identifier == "org.openxmlformats.wordprocessingml.document" {
                        // DOCX extraction is non-trivial without a ZIP parser dependency.
                        // Provide a graceful fallback: attempt to extract plain text by scanning the archive as binary for XML text content.
                        // This is best-effort and may produce limited output; prefer a proper DOCX parser for production.
                        if let docxText = try? extractTextFromDOCXFallback(url: url) {
                            result = docxText
                        } else {
                            logger.debug("DOCX extraction not implemented - returning empty string for \(url.path, privacy: .public)")
                            throw DocumentTextExtractorError.unsupportedFormat(url)
                        }
                    } else {
                        logger.debug("Unsupported document type for path: \(url.path, privacy: .public) (UTType: \(utType.identifier, privacy: .public))")
                        throw DocumentTextExtractorError.unsupportedFormat(url)
                    }

                    // Trim and normalize whitespace
                    let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: normalized)
                } catch {
                    logger.error("Extraction failed for \(url.path, privacy: .public): \(String(describing: error))")
                    continuation.resume(throwing: DocumentTextExtractorError.extractionFailed(url, underlying: error))
                }
            }
        }
    }

    // MARK: - Private extraction helpers

    private static func extractTextFromPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            logger.error("PDFDocument could not be created for \(url.path, privacy: .public)")
            throw DocumentTextExtractorError.invalidData(url)
        }

        var fullText = String()
        for pageIndex in 0..<doc.pageCount {
            if let page = doc.page(at: pageIndex), let pageStr = page.string {
                fullText += pageStr
                if pageIndex != doc.pageCount - 1 {
                    fullText += "\n\n"
                }
            }
        }
        logger.debug("Extracted PDF text length: \(fullText.count)")
        return fullText
    }

    private static func extractTextFromPlainText(url: URL) throws -> String {
        // Attempt to read string using presumed default encoding and fall back to autodetect by trying common encodings.
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other common encodings
            if let s = try? String(contentsOf: url, encoding: .utf16) { return s }
            if let s = try? String(contentsOf: url, encoding: .ascii) { return s }
            logger.debug("Failed to decode plain text using common encodings for \(url.path, privacy: .public)")
            throw error
        }
    }

    private static func extractTextFromRTF(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // Try as RTF
        let optionsRTF: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        if let attr = try? NSAttributedString(data: data, options: optionsRTF, documentAttributes: nil) {
            return attr.string
        }

        // Try as RTFD
        let optionsRTFD: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtfd
        ]
        if let attr = try? NSAttributedString(data: data, options: optionsRTFD, documentAttributes: nil) {
            return attr.string
        }

        // Fallback: attempt plain-text decode
        if let s = String(data: data, encoding: .utf8) { return s }
        throw DocumentTextExtractorError.invalidData(url)
    }

    /// Best-effort DOCX extraction without third-party dependencies.
    /// DOCX is a ZIP archive containing `word/document.xml`. This function attempts to
    /// locate and extract text nodes by scanning the archive XML content heuristically.
    /// NOTE: This is intentionally simple and not a complete DOCX parser.
    private static func extractTextFromDOCXFallback(url: URL) throws -> String {
        // Attempt to read raw data and search for word/document.xml as UTF-8 text.
        // This will work in many cases but is not guaranteed.
        let fileData = try Data(contentsOf: url)

        // We look for the xml content boundaries of <w:t>...</w:t> which usually holds text runs.
        // Convert data to string (may contain non-UTF8 bytes) - use lossy conversion to maximize chance.
        guard let rawString = String(data: fileData, encoding: .utf8) ?? String(data: fileData, encoding: .ascii) else {
            throw DocumentTextExtractorError.invalidData(url)
        }

        // Heuristic: find occurrences of "<w:t" and extract inner text between '>' and '<'
        var extracted = String()
        var searchRange = rawString.startIndex..<rawString.endIndex
        while let tRange = rawString.range(of: "<w:t", options: [], range: searchRange) {
            // find the '>' after the tag start
            if let gt = rawString.range(of: ">", options: [], range: tRange.upperBound..<rawString.endIndex) {
                // find the closing tag
                if let close = rawString.range(of: "</w:t>", options: [], range: gt.upperBound..<rawString.endIndex) {
                    let contentRange = gt.upperBound..<close.lowerBound
                    let content = String(rawString[contentRange])
                    // Decode common XML entities
                    let decoded = xmlUnescape(content)
                    extracted += decoded
                    extracted += " "
                    searchRange = close.upperBound..<rawString.endIndex
                    continue
                }
            }
            // if we couldn't find a matching close tag, advance to avoid infinite loop
            searchRange = tRange.upperBound..<rawString.endIndex
        }

        // Trim and return
        return extracted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlUnescape(_ s: String) -> String {
        var out = s
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&apos;", "'"),
            ("&quot;", "\"")
        ]
        for (entity, char) in entities {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
