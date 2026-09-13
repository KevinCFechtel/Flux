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

private enum ArticleImageCacheLookupSource {
    case visible
    case prefetch
}

private struct ArticleImageCacheMetrics: Sendable {
    let visibleHits: Int
    let visibleMisses: Int
    let prefetchHits: Int
    let prefetchMisses: Int
    let insertions: Int
    let evictions: Int
}

private final class ArticleImageCache: NSObject, NSCacheDelegate, @unchecked Sendable {
    let storage = NSCache<NSString, ArticleImageCacheEntry>()
    private let lock = NSLock()
    private var visibleHits = 0
    private var visibleMisses = 0
    private var prefetchHits = 0
    private var prefetchMisses = 0
    private var insertions = 0
    private var evictions = 0

    override init() {
        super.init()
        storage.delegate = self
    }

    func image(for key: NSString) -> CGImage? {
        storage.object(forKey: key)?.image
    }

    func lookup(_ key: NSString, source: ArticleImageCacheLookupSource) -> CGImage? {
        let image = image(for: key)
        lock.lock()
        switch (source, image == nil) {
        case (.visible, false): visibleHits += 1
        case (.visible, true): visibleMisses += 1
        case (.prefetch, false): prefetchHits += 1
        case (.prefetch, true): prefetchMisses += 1
        }
        lock.unlock()
        return image
    }

    func insert(_ image: CGImage, for key: NSString) {
        lock.lock()
        insertions += 1
        lock.unlock()
        storage.setObject(ArticleImageCacheEntry(image: image), forKey: key, cost: image.width * image.height * 4)
    }

    func snapshot() -> ArticleImageCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        return .init(visibleHits: visibleHits, visibleMisses: visibleMisses, prefetchHits: prefetchHits, prefetchMisses: prefetchMisses, insertions: insertions, evictions: evictions)
    }

    func resetMetrics() {
        lock.lock()
        visibleHits = 0; visibleMisses = 0; prefetchHits = 0; prefetchMisses = 0
        insertions = 0; evictions = 0
        lock.unlock()
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        lock.lock()
        evictions += 1
        lock.unlock()
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
        let memoryCacheHits: Int
        let memoryCacheMisses: Int
        let visibleMemoryCacheHits: Int
        let visibleMemoryCacheMisses: Int
        let prefetchMemoryCacheHits: Int
        let prefetchMemoryCacheMisses: Int
        let memoryCacheInsertions: Int
        let memoryCacheEvictions: Int
        let memoryCacheCostLimit: Int
        let inFlightDedupHits: Int
        let startedOperations: Int
        let completedOperations: Int
        let retiredOperations: Int
        let maximumActiveOperations: Int
        let visibleStarts: Int
        let prefetchStarts: Int
    }

    private struct Job {
        enum State { case queued, active, retiring }

        let generation: UUID
        var waiters: [UUID: CheckedContinuation<CGImage, Error>] = [:]
        var operation: Task<CGImage, Error>?
        var state: State = .queued
        let demand: Demand
    }

    private struct QueuedJob: Equatable {
        let request: ArticleImageRequest
        let generation: UUID
    }

    static let shared = ArticleImagePipeline()
    static let maximumConcurrentOperations = 3
    static let memoryCacheCostLimit = 48 * 1024 * 1024
    private static let maximumQueuedRequests = 48
    private static let maximumQueuedPrefetchRequests = 32

    private nonisolated let cache: ArticleImageCache
    private let loader: Loader
    private var jobs: [ArticleImageRequest: [UUID: Job]] = [:]
    private var visibleQueue: [QueuedJob] = []
    private var prefetchQueue: [QueuedJob] = []
    private var activeOperationCount = 0
    private var inFlightDedupHits = 0
    private var startedOperations = 0
    private var completedOperations = 0
    private var retiredOperations = 0
    private var maximumActiveOperations = 0
    private var visibleStarts = 0
    private var prefetchStarts = 0

    init(loader: Loader? = nil, memoryCacheCostLimit: Int = ArticleImagePipeline.memoryCacheCostLimit) {
        self.loader = loader ?? { url in try await Self.loadData(from: url) }
        cache = ArticleImageCache()
        cache.storage.totalCostLimit = max(1, memoryCacheCostLimit)
    }

    nonisolated func cachedImage(for request: ArticleImageRequest) -> CGImage? {
        cache.lookup(request.cacheKey, source: .visible)
    }

    func image(for request: ArticleImageRequest, demand: Demand = .visible, cacheWasChecked: Bool = false) async throws -> CGImage {
        let cacheKey = request.cacheKey
        if let image = cacheWasChecked ? cache.image(for: cacheKey) : cache.lookup(cacheKey, source: demand.cacheLookupSource) {
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
        let cacheMetrics = cache.snapshot()
        return .init(
            activeOperations: activeOperationCount,
            queuedVisibleRequests: visibleQueue.count,
            queuedPrefetchRequests: prefetchQueue.count,
            trackedRequests: jobs.values.reduce(0) { $0 + $1.count },
            memoryCacheHits: cacheMetrics.visibleHits + cacheMetrics.prefetchHits,
            memoryCacheMisses: cacheMetrics.visibleMisses + cacheMetrics.prefetchMisses,
            visibleMemoryCacheHits: cacheMetrics.visibleHits, visibleMemoryCacheMisses: cacheMetrics.visibleMisses,
            prefetchMemoryCacheHits: cacheMetrics.prefetchHits, prefetchMemoryCacheMisses: cacheMetrics.prefetchMisses,
            memoryCacheInsertions: cacheMetrics.insertions, memoryCacheEvictions: cacheMetrics.evictions,
            memoryCacheCostLimit: cache.storage.totalCostLimit, inFlightDedupHits: inFlightDedupHits,
            startedOperations: startedOperations, completedOperations: completedOperations,
            retiredOperations: retiredOperations, maximumActiveOperations: maximumActiveOperations,
            visibleStarts: visibleStarts, prefetchStarts: prefetchStarts
        )
    }

    func resetMetrics() {
        cache.resetMetrics()
        inFlightDedupHits = 0; startedOperations = 0; completedOperations = 0
        retiredOperations = 0; maximumActiveOperations = activeOperationCount; visibleStarts = 0; prefetchStarts = 0
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
            inFlightDedupHits += 1
            job.waiters[consumerID] = continuation
            store(job, for: request)
            if demand == .visible { promote(request, generation: generation) }
        } else {
            guard admit(demand) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            var job = Job(generation: UUID(), demand: demand)
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
            startedOperations += 1
            maximumActiveOperations = max(maximumActiveOperations, activeOperationCount)
            if job.demand == .visible { visibleStarts += 1 } else { prefetchStarts += 1 }
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
        completedOperations += 1
        if job.state == .retiring { retiredOperations += 1 }
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

private extension ArticleImagePipeline.Demand {
    var cacheLookupSource: ArticleImageCacheLookupSource {
        switch self {
        case .visible: .visible
        case .prefetch: .prefetch
        }
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
                let loadedImage = try await ArticleImagePipeline.shared.image(for: request, cacheWasChecked: true)
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
