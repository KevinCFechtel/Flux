import Combine
import Foundation

enum IOSSearchPaginationPolicy {
    static let pageSize: UInt32 = 50

    static func nextOffset(resultCount: Int, total: Int64) -> Int64? {
        guard Int64(resultCount) < total else { return nil }
        return Int64(resultCount)
    }

    static func canLoadMore(resultCount: Int, total: Int64, hasSearched: Bool, isSearching: Bool, isLoadingMore: Bool, hasError: Bool) -> Bool {
        hasSearched && !isSearching && !isLoadingMore && !hasError && nextOffset(resultCount: resultCount, total: total) != nil
    }

    static func deduplicated(_ articles: [ArticleSummary]) -> [ArticleSummary] {
        var seen = Set<Int64>()
        return articles.filter { seen.insert($0.id).inserted }
    }
}

struct IOSSearchRequestState {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() { generation &+= 1 }

    func isCurrent(_ request: UInt64) -> Bool { request == generation }
}

@MainActor
final class IOSSearchStore: ObservableObject {
    @Published var query = ""
    @Published private(set) var submittedQuery = ""
    @Published private(set) var results: [ArticleSummary] = []
    @Published private(set) var total: Int64 = 0
    @Published private(set) var hasSearched = false
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private(set) var core: Flux?
    private var requestState = IOSSearchRequestState()
    private var paginationExhausted = false
    private let pageSize = IOSSearchPaginationPolicy.pageSize
    var onLocalFirstMutation: () -> Void = {}

    func attach(to core: Flux) { self.core = core }

    func submit() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let core else { return }
        let requestGeneration = requestState.begin()
        let pageSize = pageSize
        submittedQuery = value
        results = []
        total = 0
        hasSearched = true
        isSearching = true
        isLoadingMore = false
        paginationExhausted = false
        errorMessage = nil

        Task { [weak self, core] in
            let result = await Task.detached {
                Result { try core.searchArticles(request: SearchArticlesRequest(query: value, offset: 0, limit: pageSize)) }
            }.value
            guard let self, self.requestState.isCurrent(requestGeneration) else { return }
            self.isSearching = false
            switch result {
            case let .success(page):
                self.total = page.total
                self.paginationExhausted = page.articles.isEmpty || Int64(page.articles.count) >= page.total
                self.results = IOSSearchPaginationPolicy.deduplicated(page.articles)
            case let .failure(error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func clear() {
        requestState.invalidate()
        query = ""
        submittedQuery = ""
        results = []
        total = 0
        hasSearched = false
        isSearching = false
        isLoadingMore = false
        paginationExhausted = false
        errorMessage = nil
    }

    func invalidate() {
        requestState.invalidate()
        isSearching = false
        isLoadingMore = false
    }

    func loadMore() {
        guard let core, hasSearched, !isSearching, !isLoadingMore, errorMessage == nil,
              !paginationExhausted,
              IOSSearchPaginationPolicy.canLoadMore(resultCount: results.count, total: total, hasSearched: hasSearched, isSearching: isSearching, isLoadingMore: isLoadingMore, hasError: errorMessage != nil) else { return }
        let requestGeneration = requestState.generation
        let offset = Int64(results.count)
        let value = submittedQuery
        isLoadingMore = true

        Task { [weak self, core] in
            let result = await Task.detached {
                Result { try core.searchArticles(request: SearchArticlesRequest(query: value, offset: offset, limit: IOSSearchPaginationPolicy.pageSize)) }
            }.value
            guard let self, self.requestState.isCurrent(requestGeneration) else { return }
            self.isLoadingMore = false
            switch result {
            case let .success(page):
                self.total = page.total
                let updated = IOSSearchPaginationPolicy.deduplicated(self.results + page.articles)
                self.paginationExhausted = page.articles.isEmpty || updated.count == self.results.count || Int64(updated.count) >= page.total
                self.results = updated
            case let .failure(error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func retry() {
        query = submittedQuery
        submit()
    }

    func setRead(_ article: ArticleSummary, read: Bool) {
        mutate(articleID: article.id, read: read)
    }

    func setStarred(_ article: ArticleSummary, starred: Bool) {
        mutate(articleID: article.id, starred: starred)
    }

    func open(_ article: ArticleSummary, completion: @escaping (String) -> Void) {
        setRead(article, read: true)
        completion(article.url)
    }

    func openReader(_ article: ArticleSummary, completion: @escaping (Result<ReaderDocument, Error>) -> Void) {
        setRead(article, read: true)
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        let requestGeneration = requestState.generation
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.readerDocumentForSearch(articleId: article.id) } }.value
            guard let self, self.requestState.isCurrent(requestGeneration) else { return }
            completion(result)
        }
    }

    func minifluxEntryURL(for article: ArticleSummary, completion: @escaping (Result<String, Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        completion(.success(core.minifluxEntryUrl(articleId: article.id)))
    }

    func saveToService(_ article: ArticleSummary, completion: @escaping (Result<SaveToServiceResult, Error>) -> Void) {
        guard let core else {
            completion(.failure(NSError(domain: "FluxNews", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flux is not configured"])))
            return
        }
        Task { [weak self, core] in
            let result = await Task.detached { Result { try core.saveToService(articleId: article.id) } }.value
            guard self != nil else { return }
            completion(result)
        }
    }

    private func mutate(articleID: Int64, read: Bool? = nil, starred: Bool? = nil) {
        guard let core else { return }
        Task { [weak self, core] in
            let result = await Task.detached {
                Result {
                    if let read { return try core.searchSetReadState(articleId: articleID, read: read) }
                    return try core.searchSetStarredState(articleId: articleID, starred: starred ?? false)
                }
            }.value
            guard let self else { return }
            switch result {
            case let .success(disposition):
                for index in self.results.indices where self.results[index].id == articleID {
                    if let read { self.results[index].isRead = read }
                    if let starred { self.results[index].isStarred = starred }
                }
                if disposition == .localFirst { self.onLocalFirstMutation() }
            case let .failure(error): self.errorMessage = error.localizedDescription
            }
        }
    }

}
