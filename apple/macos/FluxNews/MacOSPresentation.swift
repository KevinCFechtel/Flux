import AppKit
import Foundation
import ImageIO
import UserNotifications

enum StatusItemPresentation {
    static func title(unreadTotal: UInt64, hasPendingNewData: Bool) -> String { let unread = unreadTotal == 0 ? "" : unreadTotal > 999 ? "999+" : "\(unreadTotal)"; return switch (hasPendingNewData, unread.isEmpty) { case (false, _): unread; case (true, true): "•"; case (true, false): "• \(unread)" } }
    static func accessibilityValue(unreadTotal: UInt64, hasPendingNewData: Bool) -> String { let unread = unreadTotal == 1 ? String(localized: "1 unread article") : String(format: String(localized: "%lld unread articles"), unreadTotal); return hasPendingNewData ? String(format: String(localized: "%@, new data available"), unread) : unread }
}

struct FeedIconRequestState { private var inFlight = Set<String>(); mutating func begin(_ key: String, cached: Bool) -> Bool { !cached && inFlight.insert(key).inserted }; mutating func complete(_ key: String) { inFlight.remove(key) }; func isInFlight(_ key: String) -> Bool { inFlight.contains(key) } }
struct ArticleThumbnailRequestState { private var inFlight = Set<String>(); mutating func begin(_ key: String, cached: Bool) -> Bool { !cached && inFlight.insert(key).inserted }; mutating func complete(_ key: String) { inFlight.remove(key) }; func isInFlight(_ key: String) -> Bool { inFlight.contains(key) } }


enum MacOSFeedIconImagePreparation {
    static let displaySidePoints: CGFloat = 22

    static func prepare(data: Data, displayScale: CGFloat) -> NSImage? {
        let scale = max(displayScale, 1)
        let pixelSide = max(1, Int((displaySidePoints * scale).rounded(.up)))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? thumbnail.colorSpace
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelSide,
            height: pixelSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        let destination = CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide)
        context.clear(destination)
        context.addEllipse(in: destination)
        context.clip()
        context.interpolationQuality = .medium

        let imageScale = min(
            destination.width / CGFloat(thumbnail.width),
            destination.height / CGFloat(thumbnail.height)
        )
        let drawSize = CGSize(
            width: CGFloat(thumbnail.width) * imageScale,
            height: CGFloat(thumbnail.height) * imageScale
        )
        context.draw(
            thumbnail,
            in: CGRect(
                x: destination.midX - drawSize.width / 2,
                y: destination.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
        )
        guard let displayReady = context.makeImage() else { return nil }
        return NSImage(
            cgImage: displayReady,
            size: NSSize(width: displaySidePoints, height: displaySidePoints)
        )
    }
}
