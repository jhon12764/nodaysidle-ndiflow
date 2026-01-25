/*
 IndexedFile.swift
 ndi_flow

 Value type representing an indexed file in the indexing pipeline.
 Combines filesystem metadata with optional semantic embedding and indexing status.

 - Conforms to: Sendable, Codable, Hashable
 - Designed to be used in actor-safe contexts and passed across concurrency boundaries.

 Target: macOS 15+, Swift 6
*/

import Foundation
import UniformTypeIdentifiers

/// Current indexing state for an `IndexedFile`.
public enum IndexingStatus: String, Codable, Sendable, Hashable {
    /// File has been discovered and queued for indexing.
    case pending
    /// File is currently being analyzed (metadata extraction, ML inference, etc).
    case analyzing
    /// File was successfully indexed and embedding persisted.
    case indexed
    /// Indexing failed for this file; optional error message gives context.
    case failed

    public var isTerminal: Bool {
        switch self {
        case .indexed, .failed:
            return true
        default:
            return false
        }
    }
}

/// Representation of an indexed file used throughout the indexing pipeline.
///
/// This is a value type (struct) to make it cheap to copy and pass between async tasks.
/// It intentionally mirrors the important fields stored in `FileEntity` but is independent
/// of persistence concerns so it can be used by `IndexingCoordinator`, `WorkspaceAggregationService`, and tests.
public struct IndexedFile: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID

    // File system location
    public var url: URL

    // Basic metadata
    public var fileName: String
    /// UTI / content type identifier as a string (e.g. "public.png", "com.adobe.pdf")
    public var fileType: String
    /// Size in bytes
    public var fileSize: Int64

    // Timestamps from the filesystem
    public var createdDate: Date
    public var modifiedDate: Date

    // When the file was last indexed (analysis performed)
    public var indexedDate: Date?

    // Optional semantic embedding produced during analysis
    public var embedding: SemanticEmbedding?

    // Current indexing status and an optional error message for failures
    public var status: IndexingStatus
    public var errorMessage: String?

    // MARK: - Lifecycle

    public init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileType: String,
        fileSize: Int64,
        createdDate: Date,
        modifiedDate: Date,
        indexedDate: Date? = nil,
        embedding: SemanticEmbedding? = nil,
        status: IndexingStatus = .pending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileType = fileType
        self.fileSize = fileSize
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.indexedDate = indexedDate
        self.embedding = embedding
        self.status = status
        self.errorMessage = errorMessage
    }

    /// Create an `IndexedFile` by reading filesystem attributes for the provided `url`.
    /// Attempts to populate common metadata. Throws when file is missing or attributes cannot be read.
    public init(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "IndexedFile", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found: \(url.path)"])
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let created = (attrs[.creationDate] as? Date) ?? Date()
        let modified = (attrs[.modificationDate] as? Date) ?? created

        // Derive a best-effort file type identifier using UniformTypeIdentifiers
        let ext = url.pathExtension
        var contentType = "public.data"
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            contentType = ut.identifier
        } else if let resource = try? url.resourceValues(forKeys: [.contentTypeKey]), let ut = resource.contentType {
            contentType = ut.identifier
        }

        self.init(
            id: UUID(),
            url: url,
            fileName: url.lastPathComponent,
            fileType: contentType,
            fileSize: Int64(size),
            createdDate: created,
            modifiedDate: modified,
            indexedDate: nil,
            embedding: nil,
            status: .pending,
            errorMessage: nil
        )
    }

    // MARK: - Utilities

    /// Convenience accessor for a human-readable file size string.
    public var humanReadableSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Mark the indexed state with an embedding and timestamp. Returns an updated copy.
    public func markingIndexed(with embedding: SemanticEmbedding, at date: Date = Date()) -> IndexedFile {
        var copy = self
        copy.embedding = embedding
        copy.indexedDate = date
        copy.status = .indexed
        copy.errorMessage = nil
        return copy
    }

    /// Mark the file as currently analyzing. Returns an updated copy.
    public func markingAnalyzing() -> IndexedFile {
        var copy = self
        copy.status = .analyzing
        copy.errorMessage = nil
        return copy
    }

    /// Mark the file as failed with an error message. Returns an updated copy.
    public func markingFailed(_ message: String?) -> IndexedFile {
        var copy = self
        copy.status = .failed
        copy.errorMessage = message
        return copy
    }

    /// Lightweight check whether the file appears to be an image based on `fileType`.
    public var isImageType: Bool {
        // common image uti prefix
        return fileType.lowercased().contains("image") || fileType.lowercased().contains("png") || fileType.lowercased().contains("jpeg") || fileType.lowercased().contains("heic")
    }

    /// Lightweight check whether the file appears to be a document/text type based on `fileType` or extension.
    public var isDocumentType: Bool {
        let ft = fileType.lowercased()
        if ft.contains("pdf") || ft.contains("text") || ft.contains("rtf") || ft.contains("word") || ft.contains("xml") {
            return true
        }
        let ext = url.pathExtension.lowercased()
        return ["pdf", "txt", "rtf", "docx", "md"].contains(ext)
    }
}
