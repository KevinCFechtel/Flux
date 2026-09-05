import Foundation
import ImageIO
import SwiftUI

struct ArticleImageRequest: Hashable, Sendable {
    let url: URL
    let maxPixelDimension: Int

    init(url: URL, targetSize: CGSize, displayScale: CGFloat) {
        let pixels = max(targetSize.width, targetSize.height) * max(displayScale, 1)
        // Bucketing upward prevents tiny layout changes from creating duplicate decodes.
        maxPixelDimension = max(64, Int((ceil(pixels) / 64).rounded(.up)) * 64)
        self.url = url
    }
}

private final class ArticleImageCacheEntry: NSObject {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

actor ArticleImagePipeline {
    typealias Loader = @Sendable (URL) async throws -> Data

    static let shared = ArticleImagePipeline()

    private let cache = NSCache<NSString, ArticleImageCacheEntry>()
    private let loader: Loader
    private var inFlight: [ArticleImageRequest: Task<CGImage, Error>] = [:]

    init(loader: Loader? = nil) {
        self.loader = loader ?? { url in try await Self.loadData(from: url) }
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(for request: ArticleImageRequest) async throws -> CGImage {
        let cacheKey = request.cacheKey
        if let entry = cache.object(forKey: cacheKey) {
            return entry.image
        }

        let task: Task<CGImage, Error>
        if let existing = inFlight[request] {
            task = existing
        } else {
            let loader = loader
            task = Task {
                let data = try await loader(request.url)
                return try Self.downsample(data: data, maxPixelDimension: request.maxPixelDimension)
            }
            inFlight[request] = task
        }

        do {
            let image = try await task.value
            cache.setObject(ArticleImageCacheEntry(image: image), forKey: cacheKey, cost: image.width * image.height * 4)
            inFlight[request] = nil
            try Task.checkCancellation()
            return image
        } catch {
            inFlight[request] = nil
            throw error
        }
    }

    func removeAllCachedImages() {
        cache.removeAllObjects()
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            diskPath: "FluxArticleImages"
        )
        return URLSession(configuration: configuration)
    }()

    private static func loadData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    nonisolated static func downsample(data: Data, maxPixelDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ArticleImageError.invalidImageData
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ArticleImageError.invalidImageData
        }
        return image
    }
}

private extension ArticleImageRequest {
    var cacheKey: NSString { "\(url.absoluteString)|\(maxPixelDimension)" as NSString }
}

private enum ArticleImageError: Error {
    case invalidImageData
}

struct ArticleImageView: View {
    let url: URL
    let targetSize: CGSize

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
            }
        }
        .frame(width: targetSize.width, height: targetSize.height)
        .clipped()
        .task(id: ArticleImageRequest(url: url, targetSize: targetSize, displayScale: displayScale)) {
            image = nil
            do {
                let request = ArticleImageRequest(url: url, targetSize: targetSize, displayScale: displayScale)
                let loadedImage = try await ArticleImagePipeline.shared.image(for: request)
                try Task.checkCancellation()
                image = loadedImage
            } catch is CancellationError {
                // The shared load remains available to other card views and the cache.
            } catch {
                image = nil
            }
        }
        .accessibilityHidden(true)
    }
}
