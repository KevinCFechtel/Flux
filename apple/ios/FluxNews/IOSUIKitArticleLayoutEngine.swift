import UIKit

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
}

struct IOSUIKitArticleLayoutKey: Hashable {
    let input: IOSUIKitArticleLayoutInput
    let containerWidthPixels: Int

    init(_ input: IOSUIKitArticleLayoutInput) {
        self.input = input
        containerWidthPixels = Int((input.containerWidth * max(input.displayScale, 1)).rounded())
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
    let previewFrame: CGRect?
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let titleHeight: CGFloat
    let metadataHeight: CGFloat
    let previewHeight: CGFloat
    let textBlockHeight: CGFloat
}

/// Deterministic, cell-free counterpart to the current UIKit constraint geometry.
/// Text uses UIKit's bounded string layout API, not a configured cell or solver.
enum IOSUIKitArticleLayoutEngine {
    private static let textSpacing: CGFloat = 7
    private static let portraitSpacing: CGFloat = 12
    private static let landscapeSpacing: CGFloat = 14
    private static let starSlotWidth: CGFloat = 17
    private static let starSpacing: CGFloat = 8
    private static let feedIconWidth: CGFloat = 22
    private static let unreadWidth: CGFloat = 6
    private static let metadataPrimarySpacing: CGFloat = 6

    static func metrics(for input: IOSUIKitArticleLayoutInput) -> IOSUIKitArticleLayoutMetrics {
        let scale = max(input.displayScale, 1)
        let horizontalInset: CGFloat = input.containerWidth > 700 ? 28 : input.mode == .compact ? 10 : 16
        let availableWidth = max(0, input.containerWidth - horizontalInset * 2)
        let landscape = ArticlePresentationLayout.usesLandscapeVisual(mode: input.mode, availableWidth: availableWidth)
        let hasImage = input.hasImage && input.mode.showsArticleImage
        let variant: IOSUIKitArticleCellLayoutVariant = input.mode == .compact ? .compact : !hasImage ? .visualTextOnly : landscape ? .visualLandscape : .visualPortrait
        let verticalInset: CGFloat = variant == .compact ? 11 : variant == .visualLandscape ? 13 : 15
        let imageSize: CGSize
        let textWidth: CGFloat
        switch variant {
        case .visualPortrait:
            imageSize = .init(width: availableWidth, height: availableWidth / ArticlePresentationLayout.portraitImageAspectRatio)
            textWidth = availableWidth
        case .visualLandscape:
            let width = ArticlePresentationLayout.landscapeImageWidth(availableWidth: availableWidth)
            imageSize = .init(width: width, height: width / ArticlePresentationLayout.landscapeImageAspectRatio)
            // Mirrors the real constraints; do not use landscapeTextWidth here.
            textWidth = max(0, availableWidth - width - landscapeSpacing)
        default:
            imageSize = .zero
            textWidth = availableWidth
        }

        let titleFont = font(.headline, category: input.contentSizeCategory, bold: false)
        let titleHeight = height(input.title, font: titleFont, width: max(0, textWidth - starSlotWidth - starSpacing), maxLines: 0)
        let metadataHeight = metadataHeight(input, width: textWidth)
        let previewHeight = input.preview.isEmpty ? 0 : height(input.preview, font: font(.subheadline, category: input.contentSizeCategory, bold: false), width: textWidth, maxLines: input.previewLines.rawValue)
        let textBlockHeight = titleHeight + textSpacing + metadataHeight + (previewHeight > 0 ? textSpacing + previewHeight : 0)
        let contentHeight: CGFloat
        switch variant {
        case .visualPortrait: contentHeight = imageSize.height + portraitSpacing + textBlockHeight
        case .visualLandscape: contentHeight = max(imageSize.height, textBlockHeight)
        default: contentHeight = textBlockHeight
        }
        let totalHeight = roundToPixel(contentHeight + verticalInset * 2, scale: scale)
        let contentFrame = CGRect(x: horizontalInset, y: verticalInset, width: availableWidth, height: contentHeight)
        let imageFrame: CGRect? = imageSize == .zero ? nil : CGRect(x: horizontalInset, y: verticalInset, width: imageSize.width, height: imageSize.height)
        let textOrigin = variant == .visualPortrait ? CGPoint(x: horizontalInset, y: verticalInset + imageSize.height + portraitSpacing) : variant == .visualLandscape ? CGPoint(x: horizontalInset + imageSize.width + landscapeSpacing, y: verticalInset) : CGPoint(x: horizontalInset, y: verticalInset)
        let titleFrame = CGRect(x: textOrigin.x, y: textOrigin.y, width: textWidth, height: titleHeight)
        let metadataFrame = CGRect(x: textOrigin.x, y: titleFrame.maxY + textSpacing, width: textWidth, height: metadataHeight)
        let previewFrame = previewHeight == 0 ? nil : CGRect(x: textOrigin.x, y: metadataFrame.maxY + textSpacing, width: textWidth, height: previewHeight)
        return .init(variant: variant, cellSize: .init(width: input.containerWidth, height: totalHeight), contentFrame: contentFrame, imageFrame: imageFrame, textFrame: CGRect(x: textOrigin.x, y: textOrigin.y, width: textWidth, height: textBlockHeight), titleFrame: titleFrame, metadataFrame: metadataFrame, previewFrame: previewFrame, horizontalInset: horizontalInset, verticalInset: verticalInset, titleHeight: titleHeight, metadataHeight: metadataHeight, previewHeight: previewHeight, textBlockHeight: textBlockHeight)
    }

    private static func metadataHeight(_ input: IOSUIKitArticleLayoutInput, width: CGFloat) -> CGFloat {
        let category = input.contentSizeCategory
        let primaryHeight = max(feedIconWidth, font(.subheadline, category: category, bold: true).lineHeight)
        if width < 370 {
            let dateHeight = font(.caption1, category: category, bold: false).lineHeight
            return primaryHeight + 3 + dateHeight
        }
        return max(primaryHeight, font(.caption1, category: category, bold: false).lineHeight)
    }

    private static func font(_ style: UIFont.TextStyle, category: UIContentSizeCategory, bold: Bool) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        guard bold else { return font }
        return UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: font.pointSize)
    }

    private static func height(_ text: String, font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let lineHeight = font.lineHeight
        let measured = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
        return min(maxLines == 0 ? .greatestFiniteMagnitude : lineHeight * CGFloat(maxLines), ceil(measured))
    }

    private static func roundToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat { ceil(value * scale) / scale }
}
