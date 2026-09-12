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
        enum State { case queued, active, retiring }

        let generation: UUID
        var waiters: [UUID: CheckedContinuation<CGImage, Error>] = [:]
        var operation: Task<CGImage, Error>?
        var state: State = .queued
    }

    private struct QueuedJob: Equatable {
        let request: ArticleImageRequest
        let generation: UUID
    }

    static let shared = ArticleImagePipeline()
    static let maximumConcurrentOperations = 3
    private static let maximumQueuedRequests = 48
    private static let maximumQueuedPrefetchRequests = 32

    private nonisolated let cache: ArticleImageCache
    private let loader: Loader
    private var jobs: [ArticleImageRequest: [UUID: Job]] = [:]
    private var visibleQueue: [QueuedJob] = []
    private var prefetchQueue: [QueuedJob] = []
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
            trackedRequests: jobs.values.reduce(0) { $0 + $1.count }
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

        if let generation = coalescibleGeneration(for: request), var job = job(for: request, generation: generation) {
            job.waiters[consumerID] = continuation
            store(job, for: request)
            if demand == .visible { promote(request, generation: generation) }
        } else {
            guard admit(demand) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            var job = Job(generation: UUID())
            job.waiters[consumerID] = continuation
            store(job, for: request)
            let queued = QueuedJob(request: request, generation: job.generation)
            switch demand {
            case .visible: visibleQueue.append(queued)
            case .prefetch: prefetchQueue.append(queued)
            }
        }
        startAvailableOperations()
    }

    private func admit(_ demand: Demand) -> Bool {
        switch demand {
        case .prefetch:
            return prefetchQueue.count < Self.maximumQueuedPrefetchRequests && pendingCount < Self.maximumQueuedRequests
        case .visible:
            while pendingCount >= Self.maximumQueuedRequests, let queued = prefetchQueue.first {
                prefetchQueue.removeFirst()
                cancelQueuedPrefetch(queued)
            }
            return pendingCount < Self.maximumQueuedRequests
        }
    }

    private var pendingCount: Int { visibleQueue.count + prefetchQueue.count }

    private func cancelQueuedPrefetch(_ queued: QueuedJob) {
        guard let job = removeJob(for: queued.request, generation: queued.generation) else { return }
        for continuation in job.waiters.values {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func promote(_ request: ArticleImageRequest, generation: UUID) {
        let queued = QueuedJob(request: request, generation: generation)
        guard let index = prefetchQueue.firstIndex(of: queued) else { return }
        prefetchQueue.remove(at: index)
        visibleQueue.append(queued)
    }

    private func cancel(consumerID: UUID, for request: ArticleImageRequest) {
        guard let generation = generation(containing: consumerID, for: request),
              var job = job(for: request, generation: generation),
              let continuation = job.waiters.removeValue(forKey: consumerID) else { return }
        continuation.resume(throwing: CancellationError())
        guard job.waiters.isEmpty else {
            store(job, for: request)
            return
        }

        if let operation = job.operation {
            job.state = .retiring
            store(job, for: request)
            operation.cancel()
        } else {
            _ = removeJob(for: request, generation: generation)
            removeFromQueues(QueuedJob(request: request, generation: generation))
        }
    }

    private func startAvailableOperations() {
        while activeOperationCount < Self.maximumConcurrentOperations,
              let queued = nextQueuedRequest(),
              var job = job(for: queued.request, generation: queued.generation) {
            guard !job.waiters.isEmpty else {
                _ = removeJob(for: queued.request, generation: queued.generation)
                continue
            }
            let loader = loader
            let operation = Task.detached(priority: .utility) {
                let data = try await loader(queued.request.url)
                return try Self.downsample(data: data, maxPixelDimension: queued.request.maxPixelDimension)
            }
            job.operation = operation
            job.state = .active
            store(job, for: queued.request)
            activeOperationCount += 1
            Task { [weak self] in
                let result: Result<CGImage, Error>
                do { result = .success(try await operation.value) }
                catch { result = .failure(error) }
                await self?.complete(queued, result: result)
            }
        }
    }

    private func nextQueuedRequest() -> QueuedJob? {
        if !visibleQueue.isEmpty { return visibleQueue.removeFirst() }
        if !prefetchQueue.isEmpty { return prefetchQueue.removeFirst() }
        return nil
    }

    private func complete(_ queued: QueuedJob, result: Result<CGImage, Error>) {
        guard let job = removeJob(for: queued.request, generation: queued.generation) else { return }
        activeOperationCount -= 1
        if case let .success(image) = result { cache.insert(image, for: queued.request.cacheKey) }
        for continuation in job.waiters.values {
            switch result {
            case let .success(image): continuation.resume(returning: image)
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
        startAvailableOperations()
    }

    private func coalescibleGeneration(for request: ArticleImageRequest) -> UUID? {
        jobs[request]?.values.first { $0.state != .retiring }?.generation
    }

    private func generation(containing consumerID: UUID, for request: ArticleImageRequest) -> UUID? {
        jobs[request]?.values.first { $0.waiters[consumerID] != nil }?.generation
    }

    private func job(for request: ArticleImageRequest, generation: UUID) -> Job? {
        jobs[request]?[generation]
    }

    private func store(_ job: Job, for request: ArticleImageRequest) {
        jobs[request, default: [:]][job.generation] = job
    }

    private func removeJob(for request: ArticleImageRequest, generation: UUID) -> Job? {
        guard var generations = jobs[request], let job = generations.removeValue(forKey: generation) else { return nil }
        jobs[request] = generations.isEmpty ? nil : generations
        return job
    }

    private func removeFromQueues(_ queued: QueuedJob) {
        visibleQueue.removeAll { $0 == queued }
        prefetchQueue.removeAll { $0 == queued }
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
