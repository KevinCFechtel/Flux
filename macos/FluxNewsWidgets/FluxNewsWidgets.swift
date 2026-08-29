import AppIntents
import SwiftUI
import WidgetKit

enum FluxNewsWidgetScope: String, AppEnum {
    case allNews, bookmarks, category, feed
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Content")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.allNews: "All News", .bookmarks: "Bookmarks", .category: "Category", .feed: "Feed"]
}

struct FluxNewsFeedEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Feed")
    static var defaultQuery = FluxNewsFeedQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }
}

struct FluxNewsCategoryEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Category")
    static var defaultQuery = FluxNewsCategoryQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(title)") }
}

struct FluxNewsTemplateIcon: View {
    private var image: NSImage? {
        guard
            let url = Bundle.main.url(
                forResource: "FluxNewsTemplate",
                withExtension: "svg"
            ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        return image
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.tint)
        }
    }
}

struct FluxNewsFeedQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FluxNewsFeedEntity] { entities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [FluxNewsFeedEntity] { entities() }
    private func entities() -> [FluxNewsFeedEntity] {
        do {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            return try store.read(diagnostics: WidgetSnapshotDiagnostics.logger)?.feeds.map { .init(id: String($0.id), title: $0.title) } ?? []
        } catch {
            WidgetSnapshotDiagnostics.logger.error("Widget feed configuration could not read snapshot error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

struct FluxNewsCategoryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FluxNewsCategoryEntity] { entities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [FluxNewsCategoryEntity] { entities() }
    private func entities() -> [FluxNewsCategoryEntity] {
        do {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            return try store.read(diagnostics: WidgetSnapshotDiagnostics.logger)?.categories.map { .init(id: String($0.id), title: $0.title) } ?? []
        } catch {
            WidgetSnapshotDiagnostics.logger.error("Widget category configuration could not read snapshot error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

struct FluxNewsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "FluxNews Widget"
    static var description = IntentDescription("Choose the FluxNews content this widget shows.")
    @Parameter(title: "Content", default: .allNews) var scope: FluxNewsWidgetScope
    @Parameter(title: "Category") var category: FluxNewsCategoryEntity?
    @Parameter(title: "Feed") var feed: FluxNewsFeedEntity?
}

struct FluxNewsWidgetEntry: TimelineEntry { let date: Date; let model: WidgetContentModel; let snapshot: WidgetSnapshotV1?; let selection: WidgetContentSelection }

struct FluxNewsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FluxNewsWidgetEntry { .init(date: .now, model: .init(state: .ready, title: "All News", count: 12, countLabel: "unread", articles: [], lastSuccessfulSyncAt: nil), snapshot: nil, selection: .init(scope: .allNews, categoryID: nil, feedID: nil)) }
    func snapshot(for configuration: FluxNewsWidgetConfigurationIntent, in context: Context) async -> FluxNewsWidgetEntry { entry(configuration) }
    func timeline(for configuration: FluxNewsWidgetConfigurationIntent, in context: Context) async -> Timeline<FluxNewsWidgetEntry> { .init(entries: [entry(configuration)], policy: .never) }
    private func entry(_ configuration: FluxNewsWidgetConfigurationIntent) -> FluxNewsWidgetEntry {
        let result: Result<WidgetSnapshotV1?, Error> = Result {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            return try store.read(diagnostics: WidgetSnapshotDiagnostics.logger)
        }
        let scope = WidgetContentScope(rawValue: configuration.scope.rawValue) ?? .allNews
        let selection = WidgetContentSelection(scope: scope, categoryID: configuration.category.flatMap { Int64($0.id) }, feedID: configuration.feed.flatMap { Int64($0.id) })
        let model = WidgetContentModel.make(snapshotResult: result, selection: selection)
        return .init(date: .now, model: model, snapshot: try? result.get(), selection: selection)
    }
}

struct FluxNewsHeadlinesWidget: Widget {
    let kind = FluxNewsWidgetKind.headlines
    var body: some WidgetConfiguration { AppIntentConfiguration(kind: kind, intent: FluxNewsWidgetConfigurationIntent.self, provider: FluxNewsWidgetProvider()) { HeadlinesView(entry: $0) }.configurationDisplayName("FluxNews Headlines").description("Shows the latest articles from your selected FluxNews view.").supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge]) }
}

struct FluxNewsCompactStatusWidget: Widget {
    let kind = FluxNewsWidgetKind.compactStatus
    var body: some WidgetConfiguration { AppIntentConfiguration(kind: kind, intent: FluxNewsWidgetConfigurationIntent.self, provider: FluxNewsWidgetProvider()) { StatusView(entry: $0) }.configurationDisplayName("FluxNews Compact Status").description("FluxNews count and last successful sync.").supportedFamilies([.systemSmall, .systemMedium]) }
}

struct HeadlinesView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: FluxNewsWidgetEntry
    var body: some View { VStack(alignment: .leading, spacing: 8) { header; content }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6).containerBackground(for: .widget) { Color.clear } }
    private var header: some View { HStack { FluxNewsTemplateIcon(); Text(entry.model.title).font(.headline).lineLimit(1); Spacer(); Text("\(entry.model.count)").font(.headline.monospacedDigit()); Text(entry.model.countLabel).font(.caption).foregroundStyle(.secondary); Link(destination: WidgetAction.sync.url()) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Sync") } }
    @ViewBuilder private var content: some View {
        switch entry.model.state {
        case .ready, .empty:
            if entry.model.articles.isEmpty { Text(entry.model.countLabel == "bookmarked" ? "No bookmarks" : "No unread news").foregroundStyle(.secondary) }
            else if family == .systemExtraLarge { let articles = entry.model.latestArticles(limit: HeadlinesPresentation.capacity(for: family)); HStack(alignment: .top) { articleColumn(Array(articles.prefix(6))); articleColumn(Array(articles.dropFirst(6).prefix(6))) } }
            else { articleColumn(entry.model.latestArticles(limit: HeadlinesPresentation.capacity(for: family))) }
        case .noAccount: fallback("Open FluxNews to configure")
        case .awaitingSuccessfulSync: fallback("Waiting for first successful sync")
        case .missingSnapshot, .corruptSnapshot: fallback("No widget data available")
        case let .unavailableSelection(message): fallback(message)
        }
    }
    private func articleColumn(_ articles: [WidgetSnapshotV1.Article]) -> some View { VStack(alignment: .leading, spacing: 7) { ForEach(articles, id: \.id) { article in Link(destination: WidgetAction.article(article.id).url()) { HStack(spacing: 6) { FeedIcon(snapshot: entry.snapshot, feedID: article.feedID, title: article.feedTitle, dark: colorScheme == .dark); VStack(alignment: .leading, spacing: 1) { Text(article.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text(article.feedTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.accessibilityLabel("Open \(article.title) in FluxNews") } } } }
    private func fallback(_ text: String) -> some View { Text(text).font(.subheadline).foregroundStyle(.secondary) }
}

struct StatusView: View {
  @Environment(\.widgetFamily) private var family
    let entry: FluxNewsWidgetEntry
    var body: some View { VStack(alignment: .leading) { HStack { FluxNewsTemplateIcon(); Spacer(); Link(destination: WidgetAction.sync.url()) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Sync") }; Text(entry.model.title).font(.headline).lineLimit(2); Text("\(entry.model.count)").font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit(); Text(entry.model.countLabel).font(.caption).foregroundStyle(.secondary); Spacer();
      if family == .systemSmall {
          VStack(alignment: .leading, spacing: 1) {
              Text("Last sync:")
              Text(entry.model.lastSuccessfulSyncAt ?? "Never")
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else {
          Text(lastSync)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
      } }.padding(6).containerBackground(for: .widget) { Color.clear }.widgetURL(scopeURL) }
    private var scopeURL: URL { WidgetAction.open(entry.selection).url() }
    private var lastSync: String { guard let value = entry.model.lastSuccessfulSyncAt else { return "Last sync:\nNever" }; return "Last sync:\n\(value)" }
}

struct FeedIcon: View {
    let snapshot: WidgetSnapshotV1?; let feedID: Int64; let title: String; let dark: Bool
    var body: some View { Group { if let data = iconData, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() } else { Text(title.prefix(1).uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white).frame(width: 20, height: 20).background(.tint, in: RoundedRectangle(cornerRadius: 4)) } }.frame(width: 20, height: 20) }
    private var iconData: Data? { guard let feed = snapshot?.feeds.first(where: { $0.id == feedID }), let store = try? WidgetSnapshotStore() else { return nil }; return store.readIcon(relativePath: dark ? feed.darkIconFile ?? feed.normalIconFile : feed.normalIconFile) }
}

@main struct FluxNewsWidgetsBundle: WidgetBundle { var body: some Widget { FluxNewsHeadlinesWidget(); FluxNewsCompactStatusWidget() } }
