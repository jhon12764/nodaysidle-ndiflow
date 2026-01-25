//
//  ThumbnailLoader.swift
//  ndi_flow
//
//  Actor-backed thumbnail loader using QLThumbnailGenerator with an in-memory NSCache.
//  - Generates thumbnails asynchronously with a size and scale hint.
//  - Caches thumbnails keyed by URL+size to avoid repeated generation.
//  - Enforces a total cache size (approximate) to limit memory usage (default 100 MB).
//
//  Target: macOS 15+, Swift 6
//

import Foundation
import AppKit
import QuickLookThumbnailing
import OSLog

public enum ThumbnailLoaderError: LocalizedError {
    case generationFailed(URL)
    case invalidRepresentation
    case canceled
    case unsupportedURL(URL)

    public var errorDescription: String? {
        switch self {
        case .generationFailed(let url):
            return "Failed to generate thumbnail for: \(url.path)"
        case .invalidRepresentation:
            return "Thumbnail representation was invalid."
        case .canceled:
            return "Thumbnail generation was canceled."
        case .unsupportedURL(let url):
            return "Unsupported URL for thumbnail generation: \(url.path)"
        }
    }
}

/// Actor that generates and caches thumbnails using QLThumbnailGenerator and NSCache.
///
/// Usage:
///   let img = try await ThumbnailLoader.shared.thumbnail(for: url, size: CGSize(width:128, height:128))
public actor ThumbnailLoader {
    public static let shared = ThumbnailLoader()

    private let cache: NSCache<NSString, NSImage>
    private let generator: QLThumbnailGenerator
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ndiflow.app", category: "ThumbnailLoader")

    /// Approximate total cache size in bytes. Default 100 MiB.
    public var totalCacheLimitBytes: Int {
        didSet {
            cache.totalCostLimit = totalCacheLimitBytes
        }
    }

    private init(totalCacheLimitBytes: Int = 100 * 1024 * 1024) {
        self.cache = NSCache<NSString, NSImage>()
        self.totalCacheLimitBytes = totalCacheLimitBytes
        self.cache.totalCostLimit = totalCacheLimitBytes
        self.cache.countLimit = 1024 // soft limit on number of items
        self.generator = QLThumbnailGenerator.shared
    }

    // MARK: - Public API

    /// Generate or retrieve a cached thumbnail for the given file URL and size.
    /// - Parameters:
    ///   - url: file URL
    ///   - size: desired pixel size (points). The actual returned image may match this size.
    ///   - scale: display scale (backing scale). Defaults to main screen scale or 1.0.
    /// - Returns: an `NSImage` containing the thumbnail
    /// - Throws: ThumbnailLoaderError on failure
    public func thumbnail(for url: URL, size: CGSize, scale: CGFloat? = nil) async throws -> NSImage {
        // Validate input URL
        guard url.isFileURL else {
            throw ThumbnailLoaderError.unsupportedURL(url)
        }

        let effectiveScale = scale ?? (NSScreen.main?.backingScaleFactor ?? 1.0)
        let key = cacheKey(for: url, size: size, scale: effectiveScale)

        // Check cache
        if let cached = cache.object(forKey: key as NSString) {
            logger.log("Thumbnail cache hit for: \(url.path, privacy: .public) size: \(size.width)x\(size.height)@\(effectiveScale)x")
            return cached
        }

        // Generate thumbnail
        let image = try await generateThumbnail(url: url, size: size, scale: effectiveScale)

        // Store in cache with estimated cost
        let cost = approximateCost(for: image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        logger.log("Cached thumbnail for: \(url.path, privacy: .public) cost: \(cost) bytes")
        return image
    }

    /// Preload thumbnails for a batch of URLs. Launches generation tasks concurrently but bounded by internal generator.
    /// Non-fatal: errors for individual URLs are logged and not thrown.
    public func preload(urls: [URL], size: CGSize, scale: CGFloat? = nil) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    do {
                        _ = try await self.thumbnail(for: url, size: size, scale: scale)
                    } catch {
                        self.logger.debug("Preload thumbnail failed for \(url.path, privacy: .public): \(String(describing: error))")
                    }
                }
            }
        }
    }

    /// Remove a cached thumbnail for a given URL+size.
    public func removeCachedThumbnail(for url: URL, size: CGSize, scale: CGFloat? = nil) {
        let effectiveScale = scale ?? (NSScreen.main?.backingScaleFactor ?? 1.0)
        let key = cacheKey(for: url, size: size, scale: effectiveScale)
        cache.removeObject(forKey: key as NSString)
        logger.log("Removed cached thumbnail for: \(url.path, privacy: .public)")
    }

    /// Clears the entire thumbnail cache.
    public func clearCache() {
        cache.removeAllObjects()
        logger.log("Thumbnail cache cleared")
    }

    // MARK: - Private helpers

    /// Generate a thumbnail using QLThumbnailGenerator and wrap its async completion with a continuation.
    private func generateThumbnail(url: URL, size: CGSize, scale: CGFloat) async throws -> NSImage {
        // Build request. Use representation type `.thumbnail` which requests full-sized result when possible.
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: size.width * scale, height: size.height * scale),
                                                   scale: scale,
                                                   representationTypes: .all)

        // Use withCheckedThrowingContinuation to bridge the callback API to async/await
        return try await withCheckedThrowingContinuation { continuation in
            let token = generator.generateBestRepresentation(for: request) { [weak self] (thumbnail, error) in
                guard let self = self else {
                    continuation.resume(throwing: ThumbnailLoaderError.canceled)
                    return
                }

                if let error = error {
                    self.logger.error("QLThumbnailGenerator error for \(url.path, privacy: .public): \(String(describing: error))")
                    continuation.resume(throwing: ThumbnailLoaderError.generationFailed(url))
                    return
                }

                guard let rep = thumbnail else {
                    self.logger.debug("QLThumbnailGenerator returned no representation for \(url.path, privacy: .public)")
                    continuation.resume(throwing: ThumbnailLoaderError.invalidRepresentation)
                    return
                }

                // Try to obtain CGImage from representation and wrap into NSImage
                let cg = rep.cgImage
                let nsImage = NSImage(cgImage: cg, size: NSSize(width: size.width, height: size.height))
                continuation.resume(returning: nsImage)
            }

            // Note: `token` may be used to cancel the request if required. We don't hold onto it here.
            _ = token
        }
    }

    /// Create a stable cache key for URL + size + scale
    private func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String {
        return "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))@\(scale)x"
    }

    /// Approximate memory cost for an NSImage in bytes (width * height * 4 bytes per pixel)
    private func approximateCost(for image: NSImage) -> Int {
        guard let rep = image.representations.first else {
            return 1
        }
        let pixelsWide = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
        let pixelsHigh = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
        // Clamp to reasonable values
        let w = max(1, pixelsWide)
        let h = max(1, pixelsHigh)
        let bytes = w * h * 4
        return bytes
    }
}

// MARK: - NSImage helper
private extension NSImage {
    /// Resize an NSImage preserving aspect ratio (best-effort).
    func resized(to targetSize: NSSize) -> NSImage {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        let rect = NSRect(origin: .zero, size: targetSize)
        self.draw(in: rect, from: NSRect(origin: .zero, size: self.size), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        newImage.size = targetSize
        return newImage
    }
}
