//
//  FileEntity.swift
//  ndi_flow
//
//  SwiftData @Model representing indexed files on disk.
//  Stores file metadata and links to an optional embedding entity.
//
//  Notes:
//  - `pathURL` is intended to be indexed for efficient lookups.
//  - Relationship to `EmbeddingEntity` is one-to-one; embeddings should be cascade-deleted with the file.
//  - This model is designed for SwiftData usage on macOS 15+ with the Observation framework.
//

import Foundation
import SwiftData

@Model
final class FileEntity: Identifiable {
    // Primary identifier
    var id: UUID

    // File system URL to the file.
    var pathURL: URL

    // Basic metadata
    var fileName: String
    var fileType: String
    var fileSize: Int64

    // Timestamps from the file system
    var createdDate: Date
    var modifiedDate: Date

    // When the file was last indexed / analyzed by the system
    var indexedDate: Date?

    // One-to-one relationship to an embedding entity.
    // Cascade delete semantics are expected so that removing a FileEntity also removes its EmbeddingEntity.
    @Relationship(deleteRule: .cascade)
    var embedding: EmbeddingEntity?

    // Convenience computed properties
    var isIndexed: Bool {
        indexedDate != nil
    }

    // Initializer
    init(
        id: UUID = UUID(),
        pathURL: URL,
        fileName: String,
        fileType: String,
        fileSize: Int64,
        createdDate: Date,
        modifiedDate: Date,
        indexedDate: Date? = nil,
        embedding: EmbeddingEntity? = nil
    ) {
        self.id = id
        self.pathURL = pathURL
        self.fileName = fileName
        self.fileType = fileType
        self.fileSize = fileSize
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.indexedDate = indexedDate
        self.embedding = embedding
    }

    // Small helpers
    func updateMetadata(from attributes: FileAttributes) {
        // Update common file metadata; keep indexedDate as-is unless explicitly changed.
        self.fileName = attributes.fileName
        self.fileType = attributes.fileType
        self.fileSize = attributes.fileSize
        self.createdDate = attributes.createdDate
        self.modifiedDate = attributes.modifiedDate
    }

    func markIndexed(date: Date = Date()) {
        self.indexedDate = date
    }
}

// A lightweight struct for passing file metadata around in the indexing pipeline.
// Not a SwiftData model.
struct FileAttributes: Sendable {
    var fileName: String
    var fileType: String
    var fileSize: Int64
    var createdDate: Date
    var modifiedDate: Date
}

// Formatting helpers
extension FileEntity {
    var humanReadableSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
