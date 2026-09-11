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

private final class ArticleImageCache: @unchecked Sendable {
    let storage = NSCache<NSString, ArticleImageCacheEntry>()

    func image(for key: NSString) -> CGImage? {
        storage.object(forKey: key)?.image
    }

    func insert(_ image: CGImage, for key: NSString) {
        storage.setObject(ArticleImageCacheEntry(image: image), forKey: key, cost: image.width * image.height * 4)
    }
}

actor ArticleImagePipeline {
    typealias Loader = @Sendable (URL) async throws -> Data

    enum Demand: Equatable, Sendable { case visible, prefetch }

    struct Metrics: Equatable, Sendable {
        let activeOperations: Int
        let queuedVisibleRequests: Int
        let queuedPrefetchRequests: Int
        let trackedRequests: Int
    }

    private struct Job {
        var waiters: [UUID: CheckedContinuation<CGImage, Error>] = [:]
        var operation: Task<CGImage, Error>?
    }

    static let shared = ArticleImagePipeline()
    static let maximumConcurrentOperations = 3
    private static let maximumQueuedVisibleRequests = 48
    private static let maximumQueuedPrefetchRequests = 32

    private nonisolated let cache: ArticleImageCache
    private let loader: Loader
    private var jobs: [ArticleImageRequest: Job] = [:]
    private var visibleQueue: [ArticleImageRequest] = []
    private var prefetchQueue: [ArticleImageRequest] = []
    private var activeOperationCount = 0

    init(loader: Loader? = nil) {
        self.loader = loader ?? { url in try await Self.loadData(from: url) }
        cache = ArticleImageCache()
        cache.storage.totalCostLimit = 48 * 1024 * 1024
    }

    nonisolated func cachedImage(for request: ArticleImageRequest) -> CGImage? {
        cache.image(for: request.cacheKey)
    }

    func image(for request: ArticleImageRequest, demand: Demand = .visible) async throws -> CGImage {
        let cacheKey = request.cacheKey
        if let image = cache.image(for: cacheKey) {
            return image
        }

        let consumerID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attach(consumerID: consumerID, to: request, demand: demand, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(consumerID: consumerID, for: request) }
        }
    }

    func prefetch(_ request: ArticleImageRequest) async throws -> CGImage {
        try await image(for: request, demand: .prefetch)
    }

    func prefetch(_ requests: [ArticleImageRequest]) async {
        for request in Set(requests) {
            _ = try? await prefetch(request)
        }
    }

    func metrics() -> Metrics {
        .init(
            activeOperations: activeOperationCount,
            queuedVisibleRequests: visibleQueue.count,
            queuedPrefetchRequests: prefetchQueue.count,
            trackedRequests: jobs.count
        )
    }

    func removeAllCachedImages() {
        cache.storage.removeAllObjects()
    }

    private func attach(
        consumerID: UUID,
        to request: ArticleImageRequest,
        demand: Demand,
        continuation: CheckedContinuation<CGImage, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let cached = cache.image(for: request.cacheKey) {
            continuation.resume(returning: cached)
            return
        }

        if var job = jobs[request] {
            job.waiters[consumerID] = continuation
            jobs[request] = job
            if demand == .visible { promote(request) }
        } else {
            if !canQueue(demand) {
                continuation.resume(throwing: CancellationError())
                return
            }
            var job = Job()
            job.waiters[consumerID] = continuation
            jobs[request] = job
            switch demand {
            case .visible: visibleQueue.append(request)
            case .prefetch: prefetchQueue.append(request)
            }
        }
        startAvailableOperations()
    }

    private func canQueue(_ demand: Demand) -> Bool {
        switch demand {
        case .prefetch:
            return prefetchQueue.count < Self.maximumQueuedPrefetchRequests
        case .visible:
            while visibleQueue.count >= Self.maximumQueuedVisibleRequests,
                  let request = prefetchQueue.first {
                prefetchQueue.removeFirst()
                cancelQueuedPrefetch(request)
            }
            return visibleQueue.count < Self.maximumQueuedVisibleRequests
        }
    }

    private func cancelQueuedPrefetch(_ request: ArticleImageRequest) {
        guard let job = jobs.removeValue(forKey: request) else { return }
        for continuation in job.waiters.values {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func promote(_ request: ArticleImageRequest) {
        guard jobs[request]?.operation == nil,
              let index = prefetchQueue.firstIndex(of: request) else { return }
        prefetchQueue.remove(at: index)
        if !visibleQueue.contains(request) { visibleQueue.append(request) }
    }

    private func cancel(consumerID: UUID, for request: ArticleImageRequest) {
        guard var job = jobs[request], let continuation = job.waiters.removeValue(forKey: consumerID) else { return }
        continuation.resume(throwing: CancellationError())
        guard job.waiters.isEmpty else {
            jobs[request] = job
            return
        }

        if let operation = job.operation {
            jobs[request] = job
            operation.cancel()
        } else {
            jobs[request] = nil
            visibleQueue.removeAll { $0 == request }
            prefetchQueue.removeAll { $0 == request }
        }
    }

    private func startAvailableOperations() {
        while activeOperationCount < Self.maximumConcurrentOperations,
              let request = nextQueuedRequest(),
              var job = jobs[request] {
            guard !job.waiters.isEmpty else {
                jobs[request] = nil
                continue
            }
            let loader = loader
            let operation = Task.detached(priority: .utility) {
                let data = try await loader(request.url)
                return try Self.downsample(data: data, maxPixelDimension: request.maxPixelDimension)
            }
            job.operation = operation
            jobs[request] = job
            activeOperationCount += 1
            Task { [weak self] in
                let result: Result<CGImage, Error>
                do { result = .success(try await operation.value) }
                catch { result = .failure(error) }
                await self?.complete(request: request, result: result)
            }
        }
    }

    private func nextQueuedRequest() -> ArticleImageRequest? {
        if !visibleQueue.isEmpty { return visibleQueue.removeFirst() }
        if !prefetchQueue.isEmpty { return prefetchQueue.removeFirst() }
        return nil
    }

    private func complete(request: ArticleImageRequest, result: Result<CGImage, Error>) {
        guard let job = jobs.removeValue(forKey: request) else { return }
        activeOperationCount -= 1
        if case let .success(image) = result { cache.insert(image, for: request.cacheKey) }
        for continuation in job.waiters.values {
            switch result {
            case let .success(image): continuation.resume(returning: image)
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
        startAvailableOperations()
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
        let request = ArticleImageRequest(url: url, targetSize: targetSize, displayScale: displayScale)
        let displayedImage = image ?? ArticleImagePipeline.shared.cachedImage(for: request)
        Group {
            if let displayedImage {
                Image(decorative: displayedImage, scale: displayScale, orientation: .up)
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
        .task(id: request) {
            if let cachedImage = ArticleImagePipeline.shared.cachedImage(for: request) {
                image = cachedImage
                return
            }
            image = nil
            do {
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

extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
