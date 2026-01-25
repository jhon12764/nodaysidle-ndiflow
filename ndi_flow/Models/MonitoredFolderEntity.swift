//
//  MonitoredFolderEntity.swift
//  ndi_flow
//
//  SwiftData @Model representing a folder that should be monitored for file changes.
//  Links to a WorkspaceEntity so files in this folder are added to that workspace.
//
//  Target: macOS 15+, Swift 6, SwiftData
//

import Foundation
import SwiftData

@Model
final class MonitoredFolderEntity: Identifiable {
    // Primary identifier
    var id: UUID

    // The folder path being monitored
    var folderURL: URL

    // Display name for the folder (defaults to folder name)
    var displayName: String

    // Whether monitoring is currently enabled
    var isEnabled: Bool

    // When this folder was added to monitoring
    var addedDate: Date

    // The workspace that files from this folder should be added to
    @Relationship(deleteRule: .nullify)
    var workspace: WorkspaceEntity?

    // Store workspace ID directly to avoid SwiftData relationship access issues
    var workspaceID: UUID?

    // Security-scoped bookmark data for sandbox access
    var bookmarkData: Data?

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        folderURL: URL,
        displayName: String? = nil,
        isEnabled: Bool = true,
        addedDate: Date = Date(),
        workspace: WorkspaceEntity? = nil
    ) {
        self.id = id
        self.folderURL = folderURL
        self.displayName = displayName ?? folderURL.lastPathComponent
        self.isEnabled = isEnabled
        self.addedDate = addedDate
        self.workspace = workspace
        self.workspaceID = workspace?.id

        // Try to create a security-scoped bookmark
        do {
            self.bookmarkData = try folderURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            self.bookmarkData = nil
        }
    }

    // MARK: - Utilities

    /// Resolve the folder URL from bookmark data (for sandbox access)
    func resolveBookmark() -> URL? {
        guard let data = bookmarkData else { return folderURL }

        var isStale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Refresh bookmark
                bookmarkData = try? resolved.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }

            return resolved
        } catch {
            return folderURL
        }
    }

    /// Start accessing the security-scoped resource
    func startAccessing() -> Bool {
        guard let resolved = resolveBookmark() else { return false }
        return resolved.startAccessingSecurityScopedResource()
    }

    /// Stop accessing the security-scoped resource
    func stopAccessing() {
        guard let resolved = resolveBookmark() else { return }
        resolved.stopAccessingSecurityScopedResource()
    }
}
