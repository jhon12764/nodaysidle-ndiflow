//
//  PersistenceController.swift
//  ndi_flow
//
//  Provides a shared ModelContainer for SwiftData persistence.
//
//  Target: macOS 15+, SwiftUI 6, SwiftData
//
//  Notes:
//  - The app uses a single shared PersistenceController to create and expose a `ModelContainer`
//    initialized with the app's SwiftData models.
//  - By default the ModelContainer is created using SwiftData's default persistence behavior.
//    For custom file locations (Application Support, CloudKit configurations, etc.) adjust the
//    container creation logic as SwiftData APIs evolve.
//  - This file intentionally keeps the surface minimal: create the container, expose it, and
//    provide a convenience preview / in-memory configuration for tests and previews.
//

import Foundation
import SwiftData
import OSLog

@MainActor
final class PersistenceController {
    // Shared singleton used by the app
    static let shared = PersistenceController()

    // The ModelContainer used by SwiftData views and services.
    // Inject this into SwiftUI via `.modelContainer(...)`.
    let container: ModelContainer

    // Main context for use on @MainActor
    lazy var mainContext: ModelContext = {
        ModelContext(container)
    }()

    // Logger for persistence-related events
    private let logger = Logger(subsystem: "com.ndiflow.app", category: "Persistence")

    // MARK: - Initialization

    private init() {
        // The list of model types must match the @Model types defined in the app.
        // Keep this list in sync with the Models folder.
        do {
            self.container = try ModelContainer(
                for: FileEntity.self,
                EmbeddingEntity.self,
                WorkspaceEntity.self,
                WorkspaceMembership.self,
                MonitoredFolderEntity.self
            )
            logger.log("ModelContainer initialized successfully.")
        } catch {
            // If ModelContainer fails to initialize there's no clean recovery at runtime:
            // log the error and abort. In production you might surface an error to the user
            // and offer to rebuild the model store.
            logger.fault("Failed to initialize ModelContainer: \(String(describing: error))")
            fatalError("Unable to initialize ModelContainer: \(error.localizedDescription)")
        }
    }

    // MARK: - Utilities

    /// Create an ephemeral in-memory controller useful for previews and tests.
    /// Usage: `let preview = PersistenceController.inMemory`
    static let inMemory: PersistenceController = {
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: FileEntity.self,
                EmbeddingEntity.self,
                WorkspaceEntity.self,
                WorkspaceMembership.self,
                MonitoredFolderEntity.self,
                configurations: config
            )
            let controller = PersistenceController(unsafeContainer: container)
            controller.logger.debug("In-memory ModelContainer created for previews/tests.")
            return controller
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }()

    /// Internal initializer used to wrap an already-created ModelContainer (mainly for testing)
    /// This keeps the public shared singleton initializer simple while allowing in-memory variants.
    private init(unsafeContainer: ModelContainer) {
        self.container = unsafeContainer
        logger.log("PersistenceController initialized with provided ModelContainer.")
    }

    /// Returns the recommended Application Support directory for the app.
    /// Note: SwiftData may manage file locations internally; this helper is provided for
    /// other persistence needs (logs, caches, manual files) and for future customization.
    static func applicationSupportDirectory() -> URL {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ndiflow.app"
        do {
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let appSupport = base.appendingPathComponent(bundleID, isDirectory: true)
            if !fm.fileExists(atPath: appSupport.path) {
                try fm.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
            }
            return appSupport
        } catch {
            // Fallback to temporary directory if Application Support cannot be used.
            let tmp = fm.temporaryDirectory.appendingPathComponent(bundleID, isDirectory: true)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: nil)
            Logger.persistence.error("Failed to create Application Support directory, falling back to temporary directory: \(String(describing: error))")
            return tmp
        }
    }

    /// Create a new background context for background operations.
    func newBackgroundContext() -> ModelContext {
        return ModelContext(container)
    }
}
