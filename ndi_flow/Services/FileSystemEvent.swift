//
//  FileSystemEvent.swift
//  ndi_flow
//
//  Defines the FileSystemEvent value type and FileEventType enum used by the FileMonitorService.
//  Conforms to Sendable so it can be safely sent across concurrency domains and to Codable for
//  persistence / test fixtures. Also implements Equatable & Hashable for use in sets/maps and
//  de-duplication during debouncing.
//
//  Target: macOS 15+, Swift 6
//

import Foundation

/// Types of filesystem events the monitor emits.
public enum FileEventType: String, Codable, Sendable {
    /// A new file or directory was created.
    case created
    /// An existing file or directory was modified.
    case modified
    /// A file or directory was removed.
    case deleted
    /// A file or directory was renamed or moved. When `.renamed` is used, `oldPath` should be provided.
    case renamed

    /// Helper to determine whether the event represents a destructive change (delete or rename away).
    public var isRemovalLike: Bool {
        switch self {
        case .deleted: return true
        case .renamed: return true
        default: return false
        }
    }
}

/// A structured filesystem event emitted by the file monitoring subsystem.
///
/// - Note: This is intentionally a value type (struct) to make it cheap to copy and pass through
///   async streams. Conforms to `Sendable` so it can be transported safely between tasks.
public struct FileSystemEvent: Identifiable, Codable, Sendable, Equatable, Hashable {
    // MARK: - Public properties

    /// Unique identifier for this event.
    public var id: UUID

    /// The kind of event that occurred.
    public var eventType: FileEventType

    /// The affected file or directory path.
    public var filePath: URL

    /// For rename/move events, the original path prior to the rename/move (if available).
    public var oldPath: URL?

    /// When the event was observed by the monitor.
    public var timestamp: Date

    // MARK: - Init

    /// Create a new filesystem event.
    /// - Parameters:
    ///   - id: Optional UUID for the event. Default creates a new UUID.
    ///   - eventType: The type of the event.
    ///   - filePath: The new/current path of the file.
    ///   - oldPath: Previous path for rename events.
    ///   - timestamp: The time the event was observed. Defaults to `Date()`.
    public init(id: UUID = UUID(), eventType: FileEventType, filePath: URL, oldPath: URL? = nil, timestamp: Date = Date()) {
        self.id = id
        self.eventType = eventType
        self.filePath = filePath
        self.oldPath = oldPath
        self.timestamp = timestamp
    }

    // MARK: - Convenience factories

    public static func creation(at url: URL, timestamp: Date = Date()) -> FileSystemEvent {
        FileSystemEvent(eventType: .created, filePath: url, timestamp: timestamp)
    }

    public static func modification(at url: URL, timestamp: Date = Date()) -> FileSystemEvent {
        FileSystemEvent(eventType: .modified, filePath: url, timestamp: timestamp)
    }

    public static func deletion(at url: URL, timestamp: Date = Date()) -> FileSystemEvent {
        FileSystemEvent(eventType: .deleted, filePath: url, timestamp: timestamp)
    }

    public static func rename(from oldURL: URL, to newURL: URL, timestamp: Date = Date()) -> FileSystemEvent {
        FileSystemEvent(eventType: .renamed, filePath: newURL, oldPath: oldURL, timestamp: timestamp)
    }

    // MARK: - Computed helpers

    /// True when this event represents a rename from `oldPath` -> `filePath`.
    public var isRename: Bool {
        eventType == .renamed && oldPath != nil
    }

    /// A short human-readable summary useful for logs.
    public var summary: String {
        switch eventType {
        case .created:
            return "Created: \(filePath.path)"
        case .modified:
            return "Modified: \(filePath.path)"
        case .deleted:
            return "Deleted: \(filePath.path)"
        case .renamed:
            if let old = oldPath?.path {
                return "Renamed: \(old) -> \(filePath.path)"
            } else {
                return "Renamed: \(filePath.path)"
            }
        }
    }
}

// MARK: - CustomStringConvertible

extension FileSystemEvent: CustomStringConvertible {
    public var description: String {
        "\(timestamp.iso8601String) | \(summary)"
    }
}

// MARK: - Date formatting helper

private extension Date {
    /// Minimal ISO 8601 formatting for log-friendly timestamps.
    var iso8601String: String {
        // Use a static formatter to avoid repeated allocation.
        Self.iso8601Formatter.string(from: self)
    }

    nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
