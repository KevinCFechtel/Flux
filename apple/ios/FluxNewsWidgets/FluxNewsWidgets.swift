import AppIntents
import SwiftUI
import UIKit
import WidgetKit

enum FluxNewsWidgetScope: String, AppEnum {
    case allNews
    case bookmarks
    case category
    case feed

    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Content")
    )

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .allNews: .init(title: LocalizedStringResource("All News")),
        .bookmarks: .init(title: LocalizedStringResource("Bookmarks")),
        .category: .init(title: LocalizedStringResource("Category")),
        .feed: .init(title: LocalizedStringResource("Feed")),
    ]
}

struct FluxNewsFeedEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Feed")
    )
    static var defaultQuery = FluxNewsFeedQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        .init(title: "\(title)")
    }
}

struct FluxNewsCategoryEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Category")
    )
    static var defaultQuery = FluxNewsCategoryQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        .init(title: "\(title)")
    }
}

struct FluxNewsFeedQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FluxNewsFeedEntity] {
        entities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FluxNewsFeedEntity] {
        entities()
    }

    private func entities() -> [FluxNewsFeedEntity] {
        do {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            return try store.read(diagnostics: WidgetSnapshotDiagnostics.logger)?
                .feeds
                .map { .init(id: String($0.id), title: $0.title) } ?? []
        } catch {
            WidgetSnapshotDiagnostics.logger.error(
                "Widget feed configuration could not read snapshot error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}

struct FluxNewsCategoryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FluxNewsCategoryEntity] {
        entities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FluxNewsCategoryEntity] {
        entities()
    }

    private func entities() -> [FluxNewsCategoryEntity] {
        do {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            return try store.read(diagnostics: WidgetSnapshotDiagnostics.logger)?
                .categories
                .map { .init(id: String($0.id), title: $0.title) } ?? []
        } catch {
            WidgetSnapshotDiagnostics.logger.error(
                "Widget category configuration could not read snapshot error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}

struct FluxNewsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "FluxNews Widget"
    static var description = IntentDescription(
        LocalizedStringResource("Choose the FluxNews content this widget shows.")
    )

    @Parameter(
        title: LocalizedStringResource("Content"),
        default: .allNews
    )
    var scope: FluxNewsWidgetScope

    @Parameter(title: LocalizedStringResource("Category"))
    var category: FluxNewsCategoryEntity?

    @Parameter(title: LocalizedStringResource("Feed"))
    var feed: FluxNewsFeedEntity?
}

struct FluxNewsWidgetEntry: TimelineEntry {
    let date: Date
    let model: WidgetContentModel
    let snapshot: WidgetSnapshotV1?
    let selection: WidgetContentSelection
}

struct FluxNewsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FluxNewsWidgetEntry {
        .init(
            date: .now,
            model: .init(
                state: .ready,
                title: "All News",
                count: 12,
                countLabel: "unread",
                articles: [],
                lastSuccessfulSyncAt: nil
            ),
            snapshot: nil,
            selection: .init(scope: .allNews, categoryID: nil, feedID: nil)
        )
    }

    func snapshot(
        for configuration: FluxNewsWidgetConfigurationIntent,
        in context: Context
    ) async -> FluxNewsWidgetEntry {
        entry(configuration)
    }

    func timeline(
        for configuration: FluxNewsWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<FluxNewsWidgetEntry> {
        .init(entries: [entry(configuration)], policy: .never)
    }

    private func entry(
        _ configuration: FluxNewsWidgetConfigurationIntent
    ) -> FluxNewsWidgetEntry {
        let result: Result<WidgetSnapshotV1?, Error> = Result {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            return try store.read(diagnostics: WidgetSnapshotDiagnostics.logger)
        }
        let scope = WidgetContentScope(rawValue: configuration.scope.rawValue) ?? .allNews
        let selection = WidgetContentSelection(
            scope: scope,
            categoryID: configuration.category.flatMap { Int64($0.id) },
            feedID: configuration.feed.flatMap { Int64($0.id) }
        )
        return .init(
            date: .now,
            model: WidgetContentModel.make(
                snapshotResult: result,
                selection: selection
            ),
            snapshot: try? result.get(),
            selection: selection
        )
    }
}

struct FluxNewsHeadlinesWidget: Widget {
    let kind = FluxNewsWidgetKind.headlines

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: FluxNewsWidgetConfigurationIntent.self,
            provider: FluxNewsWidgetProvider()
        ) { entry in
            IOSFluxNewsHeadlinesView(entry: entry)
        }
        .configurationDisplayName("FluxNews Headlines")
        .description("Shows the latest articles from your selected FluxNews view.")
        .supportedFamilies(WidgetFamilyPolicy.headlineFamilies)
    }
}

struct FluxNewsCompactStatusWidget: Widget {
    let kind = FluxNewsWidgetKind.compactStatus

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: FluxNewsWidgetConfigurationIntent.self,
            provider: FluxNewsWidgetProvider()
        ) { entry in
            IOSFluxNewsStatusView(entry: entry)
        }
        .configurationDisplayName("FluxNews Status")
        .description("FluxNews count and last successful sync.")
        .supportedFamilies(WidgetFamilyPolicy.statusFamilies)
    }
}

private struct IOSFluxNewsHeadlinesView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    let entry: FluxNewsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "newspaper")
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(entry.model.count)")
                .font(.headline.monospacedDigit())
            Text(LocalizedStringKey(entry.model.countLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.model.state {
        case .ready, .empty:
            if entry.model.articles.isEmpty {
                Text(
                    entry.model.countLabel == "bookmarked"
                        ? "No bookmarks"
                        : "No unread news"
                )
                .foregroundStyle(.secondary)
            } else {
                articleColumn(
                    entry.model.latestArticles(
                        limit: HeadlinesPresentation.capacity(for: family)
                    )
                )
            }
        case .noAccount:
            fallback("Open FluxNews to configure")
        case .awaitingSuccessfulSync:
            fallback("Waiting for first successful sync")
        case .missingSnapshot, .corruptSnapshot:
            fallback("No widget data available")
        case let .unavailableSelection(message):
            fallback(message)
        }
    }

    private func articleColumn(
        _ articles: [WidgetSnapshotV1.Article]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(articles, id: \.id) { article in
                Link(destination: WidgetAction.article(article.id).url()) {
                    HStack(spacing: 6) {
                        IOSWidgetFeedIcon(
                            snapshot: entry.snapshot,
                            feedID: article.feedID,
                            title: article.feedTitle,
                            dark: colorScheme == .dark
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(article.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(article.feedTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityLabel("Open \(article.title) in FluxNews")
            }
        }
    }

    private func fallback(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var title: String {
        switch entry.selection.scope {
        case .allNews:
            String(localized: "All News")
        case .bookmarks:
            String(localized: "Bookmarks")
        case .category where entry.model.title == "Category":
            String(localized: "Category")
        case .feed where entry.model.title == "Feed":
            String(localized: "Feed")
        default:
            entry.model.title
        }
    }
}

private struct IOSFluxNewsStatusView: View {
    @Environment(\.widgetFamily) private var family

    let entry: FluxNewsWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inline
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            default:
                homeScreen
            }
        }
        .widgetURL(scopeURL)
    }

    private var inline: some View {
        Text("FluxNews · \(entry.model.count) \(localizedCountLabel)")
    }

    private var circular: some View {
        Gauge(value: min(Double(entry.model.count), 99), in: 0...99) {
            Image(systemName: "newspaper")
        } currentValueLabel: {
            Text("\(entry.model.count)")
                .font(.headline.monospacedDigit())
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "newspaper")
                .font(.headline)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.model.count)")
                    .font(.title3.bold().monospacedDigit())
                Text(LocalizedStringKey(entry.model.countLabel))
                    .font(.caption)
            }
            if let first = entry.model.articles.first {
                Text(first.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "newspaper")
                Spacer()
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text("\(entry.model.count)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(LocalizedStringKey(entry.model.countLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(lastSuccessfulSync)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var scopeURL: URL {
        WidgetAction.open(entry.selection).url()
    }

    private var localizedCountLabel: String {
        switch entry.model.countLabel {
        case "bookmarked":
            String(localized: "bookmarked")
        default:
            String(localized: "unread")
        }
    }

    private var title: String {
        switch entry.selection.scope {
        case .allNews:
            String(localized: "All News")
        case .bookmarks:
            String(localized: "Bookmarks")
        case .category where entry.model.title == "Category":
            String(localized: "Category")
        case .feed where entry.model.title == "Feed":
            String(localized: "Feed")
        default:
            entry.model.title
        }
    }

    private var lastSuccessfulSync: String {
        guard let value = entry.model.lastSuccessfulSyncAt,
              let date = ISO8601DateFormatter().date(from: value) else {
            return String(localized: "Never")
        }
        return String(
            format: String(localized: "Last sync: %@"),
            date.formatted(date: .abbreviated, time: .shortened)
        )
    }
}

private struct IOSWidgetFeedIcon: View {
    let snapshot: WidgetSnapshotV1?
    let feedID: Int64
    let title: String
    let dark: Bool

    var body: some View {
        Group {
            if let data = iconData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(title.prefix(1).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(width: 20, height: 20)
    }

    private var iconData: Data? {
        guard let feed = snapshot?.feeds.first(where: { $0.id == feedID }),
              let store = try? WidgetSnapshotStore() else {
            return nil
        }
        return store.readIcon(
            relativePath: dark
                ? feed.darkIconFile ?? feed.normalIconFile
                : feed.normalIconFile
        )
    }
}

@main
struct FluxNewsWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FluxNewsHeadlinesWidget()
        FluxNewsCompactStatusWidget()
    }
}
