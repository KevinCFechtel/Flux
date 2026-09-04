import SwiftUI

struct IOSFeedSettingsTarget: Identifiable {
    let id: Int64
    let title: String
}

enum IOSAddFeedDiscoveryOutcome: Equatable {
    case none
    case automatic(DiscoveredSubscription)
    case choose

    static func from(_ subscriptions: [DiscoveredSubscription]) -> Self {
        switch subscriptions.count {
        case 0: .none
        case 1: .automatic(subscriptions[0])
        default: .choose
        }
    }
}

enum IOSFeedCreationPolicy {
    static func validURL(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: value), ["http", "https"].contains(parsed.scheme?.lowercased()), parsed.host != nil else { return nil }
        return value
    }

    static func categoryTitle(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct IOSAddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: NewsreaderStore
    @State private var url = ""
    @State private var categoryID: Int64?
    @State private var candidates: [DiscoveredSubscription] = []
    @State private var selectedCandidateIndex: Int?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            if candidates.isEmpty {
                Section {
                    TextField("https://example.com", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Picker("Category", selection: $categoryID) {
                        Text("Use Miniflux default").tag(nil as Int64?)
                        ForEach(store.catalog.categories, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                    }
                } header: {
                    Text("Add Feed")
                } footer: {
                    Text("Flux asks Miniflux to discover available subscriptions.")
                }
            } else {
                Section("Choose a Feed") {
                    ForEach(candidates.indices, id: \.self) { index in
                        Button { selectedCandidateIndex = index } label: {
                            VStack(alignment: .leading) {
                                Text(candidates[index].title.isEmpty ? candidates[index].url : candidates[index].title)
                                Text(candidates[index].url).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .overlay(alignment: .trailing) {
                            if selectedCandidateIndex == index { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(candidates.isEmpty ? "Add Feed" : "Choose Feed")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(candidates.isEmpty ? "Continue" : "Add") {
                    candidates.isEmpty ? discover() : createSelectedCandidate()
                }
                .disabled(isWorking || (candidates.isEmpty ? normalizedURL == nil : selectedCandidateIndex == nil))
            }
        }
    }

    private var normalizedURL: String? {
        IOSFeedCreationPolicy.validURL(url)
    }

    private func discover() {
        guard let url = normalizedURL else { return }
        isWorking = true; error = nil
        store.discoverSubscriptions(DiscoverSubscriptionsRequest(url: url, username: nil, password: nil, userAgent: nil, fetchViaProxy: nil)) { result in
            isWorking = false
            switch result {
            case let .success(subscriptions):
                switch IOSAddFeedDiscoveryOutcome.from(subscriptions) {
                case .none: error = "Miniflux did not find a subscription for this URL."
                case let .automatic(subscription): create(feedURL: subscription.url)
                case .choose: candidates = subscriptions
                }
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }

    private func createSelectedCandidate() {
        guard let selectedCandidateIndex else { return }
        create(feedURL: candidates[selectedCandidateIndex].url)
    }

    private func create(feedURL: String) {
        isWorking = true; error = nil
        store.createFeed(CreateFeedRequest(feedUrl: feedURL, categoryId: categoryID, username: nil, password: nil, crawler: nil, userAgent: nil, scraperRules: nil, rewriteRules: nil, blocklistRules: nil, keeplistRules: nil, disabled: nil, ignoreHttpCache: nil, fetchViaProxy: nil)) { result in
            isWorking = false
            switch result {
            case .success: dismiss()
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }
}

struct IOSAddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: NewsreaderStore
    @State private var title = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Add Category") { TextField("Category name", text: $title) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Add Category")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: create)
                    .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func create() {
        guard let title = IOSFeedCreationPolicy.categoryTitle(title) else { return }
        isWorking = true; error = nil
        store.createCategory(title) { result in
            isWorking = false
            switch result {
            case .success: dismiss()
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }
}

struct IOSFeedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: NewsreaderStore
    let target: IOSFeedSettingsTarget
    @State private var preferences: FeedPreferences?
    @State private var error: String?

    var body: some View {
        Form {
            if let preferences {
                Picker("Detail Rendering", selection: Binding(get: { preferences.detailRendering }, set: updateDetailRendering)) {
                    Text("Rendered").tag(DetailRenderingMode.rendered)
                    Text("Text Only").tag(DetailRenderingMode.textOnly)
                }
                Toggle("Truncate Detail", isOn: Binding(get: { preferences.truncateDetail }, set: updateTruncateDetail))
                Toggle("Open in Miniflux", isOn: Binding(get: { preferences.openInMiniflux }, set: updateOpenInMiniflux))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(target.title)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear(perform: load)
    }

    private func load() {
        do { preferences = try store.feedPreferences(feedID: target.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func updateDetailRendering(_ mode: DetailRenderingMode) { update { try store.setFeedDetailRendering(feedID: target.id, mode: mode) } }
    private func updateTruncateDetail(_ enabled: Bool) { update { try store.setFeedTruncateDetail(feedID: target.id, enabled: enabled) } }
    private func updateOpenInMiniflux(_ enabled: Bool) { update { try store.setFeedOpenInMiniflux(feedID: target.id, enabled: enabled) } }
    private func update(_ change: () throws -> Void) {
        do { try change(); load() }
        catch { self.error = error.localizedDescription }
    }
}
