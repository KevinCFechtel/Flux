import SwiftUI

struct ArticleListActionsSettingsView: View {
    @ObservedObject var preferences: IOSArticleListActionPreferences

    private var availableActions: [IOSBottomAction] {
        IOSBottomAction.configurableActions.filter {
            !preferences.actions.contains($0)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(preferences.actions) { action in
                    HStack {
                        Label(action.settingsTitle, systemImage: action.symbolName)
                        Spacer()
                        if action != .more {
                            Button("Remove", role: .destructive) {
                                preferences.setActions(
                                    preferences.actions.filter { $0 != action }
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onMove { source, destination in
                    var actions = preferences.actions
                    actions.move(fromOffsets: source, toOffset: destination)
                    preferences.setActions(actions)
                }
            } header: {
                Text("Article List Actions")
            } footer: {
                Text("Choose the actions shown on the article list. More is always available for secondary actions.")
            }

            if !availableActions.isEmpty {
                Section("Available Actions") {
                    ForEach(availableActions) { action in
                        Button {
                            preferences.setActions(preferences.actions + [action])
                        } label: {
                            Label(action.settingsTitle, systemImage: action.symbolName)
                        }
                    }
                }
            }

            Section {
                Button("Reset to Default") {
                    preferences.resetToDefault()
                }
            }
        }
        .navigationTitle("Action Bar")
        .toolbar { EditButton() }
    }
}
