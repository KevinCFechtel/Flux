import SwiftUI
import UIKit

struct ArticleListView: View {
    @ObservedObject var store: NewsreaderStore

    var body: some View {
        Group {
            if store.isLoading && store.articles.isEmpty {
                ProgressView("Loading articles")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.articles.isEmpty {
                ContentUnavailableView("Unable to Load Articles", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if store.articles.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "newspaper")
            } else {
                    GeometryReader { proxy in
                        let horizontalInset: CGFloat = proxy.size.width > 700 ? 28 : 16
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(store.articles, id: \.id) { article in
                                ArticlePresentationView(article: article, mode: store.articlePresentationMode, previewLines: store.articlePreviewLines, availableWidth: proxy.size.width - horizontalInset * 2, store: store)
                                }
                            }
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay(alignment: .top) {
            if store.isLoading && !store.articles.isEmpty {
                ProgressView()
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }
}

private struct ArticlePresentationView: View {
    let article: ArticleSummary
    let mode: ArticlePresentationMode
    let previewLines: ArticlePreviewLines
    let availableWidth: CGFloat
    @ObservedObject var store: NewsreaderStore

    var body: some View {
        Button(action: {}) {
            Group {
                switch mode {
                case .visual:
                    visual
                case .compact:
                    compact
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Article opening will be added in a later release.")
    }

    @ViewBuilder
    private var visual: some View {
        if ArticlePresentationLayout.usesLandscapeVisual(mode: mode, availableWidth: availableWidth) {
            landscapeVisual
        } else {
            portraitVisual
        }
    }

    private var portraitVisual: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = article.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: imageURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                .accessibilityHidden(true)
            }
            articleText
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var landscapeVisual: some View {
        HStack(alignment: .top, spacing: 14) {
            if let imageURL = article.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: imageURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(width: min(260, availableWidth * 0.36))
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            }
            articleText
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            articleText
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }

    private var articleText: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if article.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Starred")
                }
            }
            HStack(spacing: 6) {
                if ArticlePresentationLayout.showsInternalUnreadIndicator(isRead: article.isRead) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                FeedIconView(feedID: article.feedId, title: article.feedTitle, store: store)
                Text(article.feedTitle)
                    .font(.subheadline.weight(.medium))
                Text("•")
                Text(date)
            }
            .foregroundStyle(.secondary)
            .font(.caption)
            if !article.preview.isEmpty {
                Text(article.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewLines.rawValue)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
    }

    private var date: String {
        ISO8601DateFormatter().date(from: article.publishedAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? article.publishedAt
    }

    private var accessibilityLabel: String {
        let state = article.isRead ? "Read" : "Unread"
        let star = article.isStarred ? ", starred" : ""
        return "\(article.title), \(article.feedTitle), \(date), \(state)\(star)"
    }
}

private struct FeedIconView: View {
    let feedID: Int64
    let title: String
    @ObservedObject var store: NewsreaderStore

    var body: some View {
        Group {
            if let data = store.feedIcons[feedID], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(title.prefix(1).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.gradient, in: Circle())
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("Feed \(title)")
        .task { store.requestFeedIcon(feedID) }
    }
}
