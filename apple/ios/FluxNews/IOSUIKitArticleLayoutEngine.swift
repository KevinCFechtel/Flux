import UIKit
import CoreText

/// Immutable geometry input. Mutable presentation pixels and read/starred state
/// are intentionally absent: they must never affect article-card geometry.
struct IOSUIKitArticleLayoutInput: Hashable {
    let title: String
    let feedTitle: String
    let publishedDate: String
    let preview: String
    let hasImage: Bool
    let hasComments: Bool
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let containerWidth: CGFloat
    let displayScale: CGFloat
    let contentSizeCategory: UIContentSizeCategory
    let localeIdentifier: String
    let layoutDirection: UIUserInterfaceLayoutDirection

    init(item: IOSUIKitArticleTimelineItem, mode: ArticlePresentationMode, previewLines: ArticlePreviewLines, containerWidth: CGFloat, displayScale: CGFloat, contentSizeCategory: UIContentSizeCategory, localeIdentifier: String, layoutDirection: UIUserInterfaceLayoutDirection) {
        title = item.content.article.title
        feedTitle = item.content.article.feedTitle
        publishedDate = item.content.publishedDate
        preview = item.content.article.preview
        hasImage = item.content.imageURL != nil
        hasComments = item.content.hasComments
        self.mode = mode
        self.previewLines = previewLines
        self.containerWidth = containerWidth
        self.displayScale = displayScale
        self.contentSizeCategory = contentSizeCategory
        self.localeIdentifier = localeIdentifier
        self.layoutDirection = layoutDirection
    }

    init(title: String, feedTitle: String, publishedDate: String, preview: String, hasImage: Bool, hasComments: Bool, mode: ArticlePresentationMode, previewLines: ArticlePreviewLines, containerWidth: CGFloat, displayScale: CGFloat, contentSizeCategory: UIContentSizeCategory, localeIdentifier: String, layoutDirection: UIUserInterfaceLayoutDirection) {
        self.title = title; self.feedTitle = feedTitle; self.publishedDate = publishedDate; self.preview = preview
        self.hasImage = hasImage; self.hasComments = hasComments; self.mode = mode; self.previewLines = previewLines
        self.containerWidth = containerWidth; self.displayScale = displayScale; self.contentSizeCategory = contentSizeCategory
        self.localeIdentifier = localeIdentifier; self.layoutDirection = layoutDirection
    }
}

struct IOSUIKitArticleLayoutKey: Hashable {
    let title: String
    let feedTitle: String
    let publishedDate: String
    let preview: String
    let hasComments: Bool
    let variant: IOSUIKitArticleCellLayoutVariant
    let previewLines: ArticlePreviewLines
    let containerWidthPixels: Int
    let displayScaleHundredths: Int
    let contentSizeCategory: String
    let layoutDirection: UIUserInterfaceLayoutDirection

    init(_ input: IOSUIKitArticleLayoutInput) {
        let scale = max(input.displayScale, 1)
        let geometry = IOSUIKitArticleGeometry(mode: input.mode, containerWidth: input.containerWidth)
        title = input.title
        feedTitle = input.feedTitle
        publishedDate = input.publishedDate
        preview = input.preview
        hasComments = input.hasComments
        variant = geometry.variant(hasImage: input.hasImage && input.mode.showsArticleImage)
        previewLines = input.previewLines
        containerWidthPixels = Int((input.containerWidth * scale).rounded())
        displayScaleHundredths = Int((scale * 100).rounded())
        contentSizeCategory = input.contentSizeCategory.rawValue
        layoutDirection = input.layoutDirection
    }
}

struct IOSUIKitArticleLayoutMetrics: Equatable {
    let variant: IOSUIKitArticleCellLayoutVariant
    let cellSize: CGSize
    let contentFrame: CGRect
    let imageFrame: CGRect?
    let textFrame: CGRect
    let titleFrame: CGRect
    let metadataFrame: CGRect
    let unreadFrame: CGRect
    let feedIconFrame: CGRect
    let feedTitleFrame: CGRect
    let commentsFrame: CGRect?
    let starFrame: CGRect
    let dateFrame: CGRect
    let previewFrame: CGRect?
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let titleHeight: CGFloat
    let metadataHeight: CGFloat
    let previewHeight: CGFloat
    let textBlockHeight: CGFloat
}

/// The non-text geometry contract shared by the renderer and deterministic sizing.
/// It deliberately has no presentation pixels or read/starred state.
struct IOSUIKitArticleGeometry: Equatable {
    static let wideInsetThreshold: CGFloat = 700
    static let compactInset: CGFloat = 10
    static let visualInset: CGFloat = 16
    static let wideInset: CGFloat = 28
    static let compactVerticalPadding: CGFloat = 11
    static let portraitVerticalPadding: CGFloat = 15
    static let landscapeVerticalPadding: CGFloat = 13
    static let textSpacing: CGFloat = 7
    static let portraitSpacing: CGFloat = 12
    static let landscapeSpacing: CGFloat = 14
    static let unreadSize: CGFloat = 6
    static let feedIconSize: CGFloat = 22
    static let starSlotSize: CGFloat = 17
    static let commentSlotSize: CGFloat = 17
    static let metadataLeadingSpacing: CGFloat = 6
    static let metadataAccessorySpacing: CGFloat = 6
    static let metadataTitleSpacing: CGFloat = 6

    let mode: ArticlePresentationMode
    let containerWidth: CGFloat
    let horizontalInset: CGFloat
    let availableWidth: CGFloat
    let isLandscapeVisual: Bool
    let verticalPadding: CGFloat

    init(mode: ArticlePresentationMode, containerWidth: CGFloat) {
        self.mode = mode
        self.containerWidth = containerWidth
        horizontalInset = containerWidth > Self.wideInsetThreshold ? Self.wideInset : mode == .compact ? Self.compactInset : Self.visualInset
        availableWidth = max(0, containerWidth - horizontalInset * 2)
        isLandscapeVisual = ArticlePresentationLayout.usesLandscapeVisual(mode: mode, availableWidth: availableWidth)
        verticalPadding = mode == .compact ? Self.compactVerticalPadding : isLandscapeVisual ? Self.landscapeVerticalPadding : Self.portraitVerticalPadding
    }

    func variant(hasImage: Bool) -> IOSUIKitArticleCellLayoutVariant {
        guard mode == .visual else { return .compact }
        guard hasImage else { return .visualTextOnly }
        return isLandscapeVisual ? .visualLandscape : .visualPortrait
    }

    func imageSize(hasImage: Bool) -> CGSize {
        guard hasImage, mode.showsArticleImage else { return .zero }
        if isLandscapeVisual {
            let width = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
            return .init(width: width, height: ArticlePresentationLayout.landscapeImageHeight(imageWidth: width))
        }
        // Match the NSLayoutConstraint multiplier used by the cell, rather than
        // the image-request helper's independently rounded target height.
        return .init(width: availableWidth, height: availableWidth * (1 / ArticlePresentationLayout.portraitImageAspectRatio))
    }

    func metadataLayout(width: CGFloat, hasComments: Bool, height: CGFloat) -> MetadataLayout {
        let trailingAccessorySlots = staticAccessorySlotWidths(hasComments: hasComments)
        let commentsWidth = hasComments ? trailingAccessorySlots[0] : 0
        let trailingAccessoriesWidth = trailingAccessorySlots.reduce(0, +) + CGFloat(max(0, trailingAccessorySlots.count - 1)) * Self.metadataAccessorySpacing
        let feedTitleWidth = max(0, width - Self.unreadSize - Self.metadataLeadingSpacing - Self.feedIconSize - Self.metadataLeadingSpacing - Self.metadataTitleSpacing - trailingAccessoriesWidth)
        return .init(
            unreadX: 0,
            feedIconX: Self.unreadSize + Self.metadataLeadingSpacing,
            feedTitleX: Self.unreadSize + Self.metadataLeadingSpacing + Self.feedIconSize + Self.metadataLeadingSpacing,
            feedTitleWidth: feedTitleWidth,
            commentsX: width - Self.starSlotSize - (hasComments ? Self.metadataAccessorySpacing + Self.commentSlotSize : 0),
            commentsWidth: commentsWidth,
            starX: width - Self.starSlotSize,
            height: height
        )
    }

    /// Future immutable accessories append a fixed width before the permanent star slot.
    func staticAccessorySlotWidths(hasComments: Bool) -> [CGFloat] {
        (hasComments ? [Self.commentSlotSize] : []) + [Self.starSlotSize]
    }

    struct MetadataLayout: Equatable {
        let unreadX: CGFloat
        let feedIconX: CGFloat
        let feedTitleX: CGFloat
        let feedTitleWidth: CGFloat
        let commentsX: CGFloat
        let commentsWidth: CGFloat
        let starX: CGFloat
        let height: CGFloat
    }
}

/// Deterministic, cell-free counterpart to the current UIKit constraint geometry.
/// Core Text typesetting is immutable and does not require main-actor view ownership.
enum IOSUIKitArticleLayoutEngine {
    static func metrics(for input: IOSUIKitArticleLayoutInput) -> IOSUIKitArticleLayoutMetrics {
        let scale = max(input.displayScale, 1)
        let geometry = IOSUIKitArticleGeometry(mode: input.mode, containerWidth: input.containerWidth)
        let hasImage = input.hasImage && input.mode.showsArticleImage
        let variant = geometry.variant(hasImage: hasImage)
        var imageSize = geometry.imageSize(hasImage: hasImage)
        if variant == .visualPortrait {
            // NSLayoutConstraint resolves the 16:9 frame on the display-pixel grid.
            imageSize.height = pixelAligned(imageSize.height, scale: scale)
        }
        let textWidth = variant == .visualLandscape ? max(0, geometry.availableWidth - imageSize.width - IOSUIKitArticleGeometry.landscapeSpacing) : geometry.availableWidth

        let titleFont = font(.headline, category: input.contentSizeCategory, bold: false)
        let titleHeight = coreTextHeight(input.title, font: titleFont, width: textWidth, maximumLines: nil, displayScale: scale)
        let metadataHeight = max(IOSUIKitArticleGeometry.feedIconSize, font(.subheadline, category: input.contentSizeCategory, bold: true).lineHeight)
        let dateHeight = fixedLineHeight(input.publishedDate, font: font(.caption1, category: input.contentSizeCategory, bold: false))
        let previewHeight = coreTextHeight(input.preview, font: font(.subheadline, category: input.contentSizeCategory, bold: false), width: textWidth, maximumLines: input.previewLines.rawValue, displayScale: scale)
        let textBlockHeight = titleHeight + IOSUIKitArticleGeometry.textSpacing + metadataHeight + IOSUIKitArticleGeometry.textSpacing + dateHeight + (previewHeight > 0 ? IOSUIKitArticleGeometry.textSpacing + previewHeight : 0)
        let contentHeight: CGFloat
        switch variant {
        case .visualPortrait: contentHeight = imageSize.height + IOSUIKitArticleGeometry.portraitSpacing + textBlockHeight
        case .visualLandscape: contentHeight = max(imageSize.height, textBlockHeight)
        default: contentHeight = textBlockHeight
        }
        let totalHeight = ceil(contentHeight + geometry.verticalPadding * 2)
        let contentFrame = CGRect(x: geometry.horizontalInset, y: geometry.verticalPadding, width: geometry.availableWidth, height: contentHeight)
        let logicalImageX = geometry.horizontalInset
        let imageFrame: CGRect? = imageSize == .zero ? nil : CGRect(x: physicalX(logicalX: logicalImageX, width: imageSize.width, in: input.containerWidth, direction: input.layoutDirection), y: geometry.verticalPadding, width: imageSize.width, height: imageSize.height)
        let logicalTextX = variant == .visualLandscape ? geometry.horizontalInset + imageSize.width + IOSUIKitArticleGeometry.landscapeSpacing : geometry.horizontalInset
        let textOrigin = CGPoint(x: physicalX(logicalX: logicalTextX, width: textWidth, in: input.containerWidth, direction: input.layoutDirection), y: variant == .visualPortrait ? geometry.verticalPadding + imageSize.height + IOSUIKitArticleGeometry.portraitSpacing : geometry.verticalPadding)
        let titleFrame = CGRect(x: textOrigin.x, y: textOrigin.y, width: textWidth, height: titleHeight)
        let metadataFrame = CGRect(x: textOrigin.x, y: titleFrame.maxY + IOSUIKitArticleGeometry.textSpacing, width: textWidth, height: metadataHeight)
        let metadataLayout = geometry.metadataLayout(width: textWidth, hasComments: input.hasComments, height: metadataHeight)
        func metadataX(_ logicalX: CGFloat, width: CGFloat) -> CGFloat { input.layoutDirection == .rightToLeft ? metadataFrame.maxX - logicalX - width : metadataFrame.minX + logicalX }
        let unreadFrame = CGRect(x: metadataX(metadataLayout.unreadX, width: IOSUIKitArticleGeometry.unreadSize), y: metadataFrame.midY - IOSUIKitArticleGeometry.unreadSize / 2, width: IOSUIKitArticleGeometry.unreadSize, height: IOSUIKitArticleGeometry.unreadSize)
        let feedIconFrame = CGRect(x: metadataX(metadataLayout.feedIconX, width: IOSUIKitArticleGeometry.feedIconSize), y: metadataFrame.midY - IOSUIKitArticleGeometry.feedIconSize / 2, width: IOSUIKitArticleGeometry.feedIconSize, height: IOSUIKitArticleGeometry.feedIconSize)
        let feedTitleFrame = CGRect(x: metadataX(metadataLayout.feedTitleX, width: metadataLayout.feedTitleWidth), y: metadataFrame.minY, width: metadataLayout.feedTitleWidth, height: metadataHeight)
        let commentsFrame = input.hasComments ? CGRect(x: metadataX(metadataLayout.commentsX, width: IOSUIKitArticleGeometry.commentSlotSize), y: metadataFrame.midY - IOSUIKitArticleGeometry.commentSlotSize / 2, width: IOSUIKitArticleGeometry.commentSlotSize, height: IOSUIKitArticleGeometry.commentSlotSize) : nil
        let starFrame = CGRect(x: metadataX(metadataLayout.starX, width: IOSUIKitArticleGeometry.starSlotSize), y: metadataFrame.midY - IOSUIKitArticleGeometry.starSlotSize / 2, width: IOSUIKitArticleGeometry.starSlotSize, height: IOSUIKitArticleGeometry.starSlotSize)
        let dateFrame = CGRect(x: textOrigin.x, y: metadataFrame.maxY + IOSUIKitArticleGeometry.textSpacing, width: textWidth, height: dateHeight)
        let previewFrame = previewHeight == 0 ? nil : CGRect(x: textOrigin.x, y: dateFrame.maxY + IOSUIKitArticleGeometry.textSpacing, width: textWidth, height: previewHeight)
        return .init(variant: variant, cellSize: .init(width: input.containerWidth, height: totalHeight), contentFrame: contentFrame, imageFrame: imageFrame, textFrame: CGRect(x: textOrigin.x, y: textOrigin.y, width: textWidth, height: textBlockHeight), titleFrame: titleFrame, metadataFrame: metadataFrame, unreadFrame: unreadFrame, feedIconFrame: feedIconFrame, feedTitleFrame: feedTitleFrame, commentsFrame: commentsFrame, starFrame: starFrame, dateFrame: dateFrame, previewFrame: previewFrame, horizontalInset: geometry.horizontalInset, verticalInset: geometry.verticalPadding, titleHeight: titleHeight, metadataHeight: metadataHeight, previewHeight: previewHeight, textBlockHeight: textBlockHeight)
    }

    private static func pixelAligned(_ length: CGFloat, scale: CGFloat) -> CGFloat {
        (length * scale).rounded() / scale
    }

    private static func physicalX(logicalX: CGFloat, width: CGFloat, in containerWidth: CGFloat, direction: UIUserInterfaceLayoutDirection) -> CGFloat {
        direction == .rightToLeft ? containerWidth - logicalX - width : logicalX
    }

    private static func font(_ style: UIFont.TextStyle, category: UIContentSizeCategory, bold: Bool) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        guard bold else { return font }
        return UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: font.pointSize)
    }

    private static func fixedLineHeight(_ text: String, font: UIFont) -> CGFloat {
        text.isEmpty ? 0 : font.lineHeight
    }

    /// Counts only the lines that can affect visible height. The unbounded title
    /// consumes every line; preview stops as soon as its configured limit is reached.
    private static func coreTextHeight(_ text: String, font: UIFont, width: CGFloat, maximumLines: Int?, displayScale: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let coreTextFont = font as CTFont
        let attributedText = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: coreTextFont])
        let typesetter = CTTypesetterCreateWithAttributedString(attributedText)
        let length = attributedText.length
        var index = 0
        var lineCount = 0
        while index < length, maximumLines.map({ lineCount < $0 }) ?? true {
            var lineLength = CTTypesetterSuggestLineBreak(typesetter, index, Double(width))
            if lineLength == 0 {
                lineLength = CTTypesetterSuggestClusterBreak(typesetter, index, Double(width))
            }
            guard lineLength > 0 else { break }
            index += lineLength
            lineCount += 1
        }
        // UILabel uses its font line height plus inter-line font leading, then
        // resolves the final label extent on the display-pixel grid.
        let height = CGFloat(lineCount) * font.lineHeight + CGFloat(max(0, lineCount - 1)) * font.leading
        return ceil(height * displayScale) / displayScale
    }
}
