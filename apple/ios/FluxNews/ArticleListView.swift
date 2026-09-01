import SwiftUI

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
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.articles, id: \.id) { article in
                                ArticlePresentationView(article: article, mode: store.articlePresentationMode, previewLines: store.articlePreviewLines, availableWidth: proxy.size.width)
                            }
                        }
                        .padding(.horizontal, proxy.size.width > 700 ? 28 : 16)
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

    private var visual: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = article.imageUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: imageURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(height: availableWidth > 700 ? 230 : 190)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)
            }
            articleText
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) { unreadMarker }
    }

    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            FeedBadge(title: article.feedTitle)
            articleText
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .overlay(alignment: .leading) { unreadMarker }
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

    private var unreadMarker: some View {
        Circle()
            .fill(article.isRead ? .clear : Color.accentColor)
            .frame(width: 8, height: 8)
            .padding(.top, 18)
            .padding(.leading, 2)
            .accessibilityHidden(true)
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

private struct FeedBadge: View {
    let title: String

    var body: some View {
        Text(title.prefix(1).uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color.accentColor.gradient, in: Circle())
            .accessibilityLabel("Feed \(title)")
    }
}
