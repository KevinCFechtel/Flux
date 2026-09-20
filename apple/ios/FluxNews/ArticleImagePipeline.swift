import Foundation
import ImageIO
import SwiftUI
import UIKit


/// Opaque colour the rounded corner cut-outs are filled with.
///
/// Baking the corners into the raster avoids a mask layer at composite time,
/// but clearing them to transparent forces an alpha channel onto the whole
/// bitmap — and Core Animation then blends every pixel of every article image
/// in every frame, purely to show four corner arcs. Filling the corners with
/// the opaque colour that sits behind the image instead lets the raster ship
/// without alpha, so the layer can be marked opaque and skipped by the blender.
///
/// Quantised to 8 bits because that is the precision the bitmap stores anyway,
/// which keeps the cache key stable against float noise.
struct ArticleImageBackdrop: Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The two colours `UIColor.systemBackground` actually resolves to, for the
    /// rare case where it cannot be read as RGB.
    static let white = ArticleImageBackdrop(red: UInt8(255), green: UInt8(255), blue: UInt8(255))
    static let black = ArticleImageBackdrop(red: UInt8(0), green: UInt8(0), blue: UInt8(0))

    init(components red: CGFloat, green: CGFloat, blue: CGFloat) {
        func quantise(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        self.init(red: quantise(red), green: quantise(green), blue: quantise(blue))
    }
}

struct ArticleImageRequest: Hashable, Sendable {
    let url: URL
    let maxPixelDimension: Int
    let targetPixelSize: CGSize
    let cornerRadiusPixels: CGFloat
    let rasterScale: CGFloat
    /// Core Animation colour-matches layer contents whose colour space differs
    /// from the display's — on the main thread, during the commit, proportional
    /// to the pixel count. The raster is produced in the display's gamut so that
    /// conversion never happens.
    let usesDisplayP3: Bool
    /// When set, the raster is produced without an alpha channel and the corner
    /// cut-outs are filled with this colour. `nil` keeps the transparent-corner
    /// behaviour, which callers that draw over an unknown background need.
    let backdrop: ArticleImageBackdrop?

    init(
        url: URL,
        targetSize: CGSize,
        displayScale: CGFloat,
        cornerRadius: CGFloat = 0,
        rasterScale: CGFloat? = nil,
        usesDisplayP3: Bool = false,
        backdrop: ArticleImageBackdrop? = nil
    ) {
        let scale = max(rasterScale ?? displayScale, 1)
        let pixels = max(targetSize.width, targetSize.height) * scale
        // Bucketing upward prevents tiny layout changes from creating duplicate decodes.
        maxPixelDimension = max(64, Int((ceil(pixels) / 64).rounded(.up)) * 64)
        targetPixelSize = .init(
            width: max(1, (targetSize.width * scale).rounded()),
            height: max(1, (targetSize.height * scale).rounded())
        )
        cornerRadiusPixels = max(0, (cornerRadius * scale).rounded())
        self.rasterScale = scale
        self.usesDisplayP3 = usesDisplayP3
        self.backdrop = backdrop
        self.url = url
    }

    /// True when the produced raster carries no alpha channel, so the presenting
    /// layer may be marked opaque.
    var producesOpaqueRaster: Bool { backdrop != nil }

    private var backdropKeyComponent: String {
        guard let backdrop else { return "alpha" }
        return "\(backdrop.red),\(backdrop.green),\(backdrop.blue)"
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
    let residentCost: Int
    let residentCount: Int
}

private final class ArticleImageCache: @unchecked Sendable {
    private final class Node {
        let key: NSString
        var image: CGImage
        var cost: Int
        weak var previous: Node?
        var next: Node?

        init(key: NSString, image: CGImage, cost: Int) {
            self.key = key
            self.image = image
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private var entries: [NSString: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?
    private var totalCost = 0
    let totalCostLimit: Int

    private var visibleHits = 0
    private var visibleMisses = 0
    private var prefetchHits = 0
    private var prefetchMisses = 0
    private var insertions = 0
    private var evictions = 0
    private var memoryWarningObserver: NSObjectProtocol?

    init(totalCostLimit: Int) {
        self.totalCostLimit = max(1, totalCostLimit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func image(for key: NSString) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = entries[key] else { return nil }
        promote(node)
        return node.image
    }

    func lookup(_ key: NSString, source: ArticleImageCacheLookupSource) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        let node = entries[key]
        if let node { promote(node) }

        switch (source, node == nil) {
        case (.visible, false): visibleHits += 1
        case (.visible, true): visibleMisses += 1
        case (.prefetch, false): prefetchHits += 1
        case (.prefetch, true): prefetchMisses += 1
        }
        return node?.image
    }

    func insert(_ image: CGImage, for key: NSString) {
        let cost = ArticleImagePipeline.memoryCost(of: image)
        lock.lock()
        defer { lock.unlock() }

        insertions += 1
        if let existing = entries[key] {
            totalCost -= existing.cost
            existing.image = image
            existing.cost = cost
            totalCost += cost
            promote(existing)
        } else {
            let node = Node(key: key, image: image, cost: cost)
            entries[key] = node
            insertAtFront(node)
            totalCost += cost
        }

        while totalCost > totalCostLimit, let candidate = leastRecent {
            remove(candidate)
            entries.removeValue(forKey: candidate.key)
            totalCost -= candidate.cost
            evictions += 1
        }
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        mostRecent = nil
        leastRecent = nil
        totalCost = 0
        lock.unlock()
    }

    func snapshot() -> ArticleImageCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            visibleHits: visibleHits,
            visibleMisses: visibleMisses,
            prefetchHits: prefetchHits,
            prefetchMisses: prefetchMisses,
            insertions: insertions,
            evictions: evictions,
            residentCost: totalCost,
            residentCount: entries.count
        )
    }

    func resetMetrics() {
        lock.lock()
        visibleHits = 0
        visibleMisses = 0
        prefetchHits = 0
        prefetchMisses = 0
        insertions = 0
        evictions = 0
        lock.unlock()
    }

    private func promote(_ node: Node) {
        guard mostRecent !== node else { return }
        remove(node)
        insertAtFront(node)
    }

    private func insertAtFront(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil { leastRecent = node }
    }

    private func remove(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if mostRecent === node { mostRecent = next }
        if leastRecent === node { leastRecent = previous }
        node.previous = nil
        node.next = nil
    }
}

actor ArticleImagePipeline {
    typealias Loader = @Sendable (URL) async throws -> Data
    typealias Transformer = @Sendable (Data, ArticleImageRequest) throws -> CGImage

    /// Fetches remain concurrent, but the CPU-heavy ImageIO + exact-slot
    /// CGContext transform is intentionally serialized. Large Hero rasters can
    /// otherwise overlap and create short CPU/memory-bandwidth spikes while the
    /// main thread is trying to sustain scrolling.
    private actor TransformExecutor {
        private let transform: Transformer

        init(transform: @escaping Transformer) {
            self.transform = transform
        }

        func render(data: Data, request: ArticleImageRequest) throws -> CGImage {
            // Cancellation while waiting for this serial executor must prevent
            // obsolete work from entering ImageIO at all.
            try Task.checkCancellation()
            return try transform(data, request)
        }
    }

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
        var demand: Demand
    }

    private struct QueuedJob: Equatable {
        let request: ArticleImageRequest
        let generation: UUID
    }

    static let shared = ArticleImagePipeline()
    static let maximumConcurrentOperations = 2
    // A visual card is commonly about 1.5-2.5 MiB decoded at @3x. This retains
    // a useful scrolling runway without allowing unbounded image memory.
    /// Display-ready rasters are retained for warm/back scrolling. 128 MiB keeps
    /// that reuse useful without making the cache unbounded under memory pressure.
    static let memoryCacheCostLimit = 128 * 1024 * 1024
    private static let maximumQueuedRequests = 48
    private static let maximumQueuedPrefetchRequests = 32

    private nonisolated let cache: ArticleImageCache
    private let loader: Loader
    private let transformExecutor: TransformExecutor
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
        transformExecutor = TransformExecutor { data, request in
            try Self.downsample(data: data, request: request)
        }
        cache = ArticleImageCache(totalCostLimit: memoryCacheCostLimit)
    }

    nonisolated func cachedImage(for request: ArticleImageRequest) -> CGImage? {
        cache.lookup(request.cacheKey, source: .visible)
    }

    nonisolated static func memoryCost(of image: CGImage) -> Int {
        image.width * image.height * 4
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
            memoryCacheCostLimit: cache.totalCostLimit, inFlightDedupHits: inFlightDedupHits,
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
        cache.removeAll()
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
        if var job = job(for: request, generation: generation) {
            job.demand = .visible
            store(job, for: request)
        }
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
            let transformExecutor = transformExecutor
            let priority: TaskPriority = job.demand == .visible ? .userInitiated : .utility
            let operation = Task.detached(priority: priority) {
                let data = try await loader(queued.request.url)
                // Some loaders cannot abandon an in-flight response immediately.
                // Once the last consumer has retired the job, do not turn bytes
                // that just arrived into an expensive display raster.
                try Task.checkCancellation()
                // Two fetches may overlap, but ImageIO thumbnail creation and the
                // exact-slot CGContext raster never execute concurrently.
                return try await transformExecutor.render(data: data, request: queued.request)
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

    nonisolated static func downsample(data: Data, request: ArticleImageRequest) throws -> CGImage {
        try Task.checkCancellation()
        let image = try thumbnail(data: data, maxPixelDimension: request.maxPixelDimension)
        // ImageIO thumbnail creation is the first CPU-heavy stage. If the cell
        // was rebound while it ran, skip the second full-slot CGContext raster.
        try Task.checkCancellation()
        let rendered = renderDisplayReady(
            image,
            targetPixelSize: request.targetPixelSize,
            cornerRadiusPixels: request.cornerRadiusPixels,
            usesDisplayP3: request.usesDisplayP3,
            backdrop: request.backdrop
        ) ?? image
        // A cancellation that arrives during CGContext drawing cannot interrupt
        // Core Graphics itself, but it must still keep the obsolete raster out
        // of the cache and away from consumers.
        try Task.checkCancellation()
        return rendered
    }

    private nonisolated static func thumbnail(data: Data, maxPixelDimension: Int) throws -> CGImage {
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

    private nonisolated static func renderDisplayReady(
        _ image: CGImage,
        targetPixelSize: CGSize,
        cornerRadiusPixels: CGFloat,
        usesDisplayP3: Bool,
        backdrop: ArticleImageBackdrop?
    ) -> CGImage? {
        let width = max(1, Int(targetPixelSize.width.rounded()))
        let height = max(1, Int(targetPixelSize.height.rounded()))
        let preferredColorSpace = usesDisplayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        let colorSpace = CGColorSpace(name: preferredColorSpace) ?? image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: backdrop == nil ? translucentBitmapInfo : displayBitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        if let backdrop {
            // The corners are the only pixels the photo does not cover, and they
            // sit directly on this colour. Painting it here is what lets the
            // raster ship without an alpha channel.
            context.setFillColor(
                red: CGFloat(backdrop.red) / 255,
                green: CGFloat(backdrop.green) / 255,
                blue: CGFloat(backdrop.blue) / 255,
                alpha: 1
            )
            context.fill(destination)
        } else {
            context.clear(destination)
        }
        if cornerRadiusPixels > 0 {
            let radius = min(cornerRadiusPixels, min(destination.width, destination.height) / 2)
            context.addPath(CGPath(
                roundedRect: destination,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.clip()
        }
        let scale = max(destination.width / CGFloat(image.width), destination.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let drawRect = CGRect(
            x: destination.midX - drawSize.width / 2,
            y: destination.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.draw(image, in: drawRect)
        return context.makeImage()
    }

    /// Native 32-bit BGRX: the display's byte order, no alpha channel. Core
    /// Animation neither converts nor blends a layer backed by this.
    private nonisolated static var displayBitmapInfo: UInt32 {
        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    }

    /// Native byte order with alpha, for callers that need transparent corners.
    private nonisolated static var translucentBitmapInfo: UInt32 {
        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
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
    var cacheKey: NSString {
        "\(url.absoluteString)|\(maxPixelDimension)|\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))|\(Int(cornerRadiusPixels))|scale=\(Int((rasterScale * 100).rounded()))|p3=\(usesDisplayP3 ? 1 : 0)|bg=\(backdropKeyComponent)" as NSString
    }
}

private enum ArticleImageError: Error {
    case invalidImageData
}


extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
