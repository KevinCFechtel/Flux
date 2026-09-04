import SwiftUI

struct AccountConfigurationView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper
    let allowsRemoval: Bool
    @State private var server: String
    @State private var apiKey: String
    @State private var headers: [IOSCustomHTTPHeader]
    @State private var removalConfirmation = false

    init(bootstrapper: CoreBootstrapper, allowsRemoval: Bool) {
        self.bootstrapper = bootstrapper
        self.allowsRemoval = allowsRemoval
        let account = bootstrapper.credentials
        _server = State(initialValue: account?.server ?? "")
        _apiKey = State(initialValue: account?.apiKey ?? "")
        _headers = State(initialValue: account?.customHeaders ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Miniflux Account") {
                    TextField("Server URL", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $apiKey)
                        .textContentType(.password)
                }
                Section {
                    ForEach($headers) { $header in
                        VStack(alignment: .leading) {
                            TextField("Header name", text: $header.name)
                                .autocorrectionDisabled()
                            SecureField("Header value", text: $header.value)
                        }
                    }
                    .onDelete { headers.remove(atOffsets: $0) }
                    Button { headers.append(IOSCustomHTTPHeader()) } label: {
                        Label("Add custom header", systemImage: "plus")
                    }
                } header: { Text("Custom HTTP Headers") }
                if let message = bootstrapper.validationMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await bootstrapper.configure(server: server, apiKey: apiKey, headers: headers) }
                    } label: {
                        if bootstrapper.isConfiguring { ProgressView() }
                        else { Text("Validate and Continue") }
                    }
                    .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.isEmpty || bootstrapper.isConfiguring)
                }
                if allowsRemoval {
                    Section {
                        Button("Remove Account", role: .destructive) { removalConfirmation = true }
                    } footer: {
                        Text("Removes this account and its local account data, but keeps global app and display preferences.")
                    }
                }
            }
            .navigationTitle(allowsRemoval ? "Account" : "Set Up FluxNews")
            .navigationBarTitleDisplayMode(allowsRemoval ? .inline : .large)
            .confirmationDialog("Remove this account?", isPresented: $removalConfirmation) {
                Button("Remove Account", role: .destructive) { Task { await bootstrapper.removeAccount() } }
            } message: {
                Text("Account data and feed preferences on this installation will be removed.")
            }
        }
    }
}

struct StartupView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper

    var body: some View {
        Group {
            switch bootstrapper.state {
            case .starting:
                ProgressView("Starting FluxNews...")
            case .accountRequired:
                AccountConfigurationView(bootstrapper: bootstrapper, allowsRemoval: false)
            case let .recoverableError(message):
                VStack(spacing: 16) {
                    ContentUnavailableView("FluxNews could not start", systemImage: "exclamationmark.triangle", description: Text(message))
                    Button("Retry") { Task { await bootstrapper.retry() } }
                    AccountConfigurationView(bootstrapper: bootstrapper, allowsRemoval: false)
                        .frame(maxHeight: 420)
                }
            case .ready:
                EmptyView()
            }
        }
    }
}
