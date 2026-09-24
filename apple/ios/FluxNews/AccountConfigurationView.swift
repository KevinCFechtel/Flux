import SwiftUI

struct AccountConfigurationView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper
    let allowsRemoval: Bool
    @State private var server: String
    @State private var apiKey: String
    @State private var headers: [IOSCustomHTTPHeader]
    @State private var removalConfirmation = false
    @State private var rebuildConfirmation = false
    let embedded: Bool

    init(bootstrapper: CoreBootstrapper, allowsRemoval: Bool, embedded: Bool = false) {
        self.bootstrapper = bootstrapper
        self.allowsRemoval = allowsRemoval
        self.embedded = embedded
        let account = bootstrapper.credentials
        _server = State(initialValue: account?.server ?? "")
        _apiKey = State(initialValue: account?.apiKey ?? "")
        _headers = State(initialValue: account?.customHeaders ?? [])
    }

    var body: some View {
        Group {
            if embedded { formContent }
            else { NavigationStack { formContent } }
        }
    }

    private var formContent: some View {
        Form {
            Section("Miniflux Account") {
                TextField("Server URL", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
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
                    Label("Add Header", systemImage: "plus")
                }
            } header: { Text("Custom HTTP Headers") }
            if let message = bootstrapper.validationMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
            if let diagnostic = bootstrapper.validationDiagnostic {
                Section("Developer Diagnostics") {
                    DisclosureGroup("Connection Diagnostics") {
                        LabeledContent("Category", value: diagnostic.category)
                        Text(diagnostic.detail)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
                    Button {
                        rebuildConfirmation = true
                    } label: {
                        if bootstrapper.localStateRebuildState == .rebuilding {
                            HStack {
                                ProgressView()
                                Text("Rebuilding Local State…")
                            }
                        } else {
                            Text("Rebuild Local State")
                        }
                    }
                    .disabled(
                        bootstrapper.localStateRebuildState == .rebuilding
                            || bootstrapper.isConfiguring
                    )

                    switch bootstrapper.localStateRebuildState {
                    case .succeeded:
                        Label("Local state rebuilt.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed:
                        Label(
                            "Local state was cleared, but synchronization could not be completed.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    case .idle, .rebuilding:
                        EmptyView()
                    }

                    Button("Remove Account", role: .destructive) { removalConfirmation = true }
                        .disabled(bootstrapper.localStateRebuildState == .rebuilding)
                } footer: {
                    Text("Rebuild discards synchronized local data and downloads it again from Miniflux while keeping this account and your settings. Remove Account also removes account-bound data and credentials.")
                }
            }
        }
        .navigationTitle(allowsRemoval ? "Account" : "Set Up FluxNews")
        .navigationBarTitleDisplayMode(allowsRemoval ? .inline : .large)
        .confirmationDialog("Rebuild Local State?", isPresented: $rebuildConfirmation) {
            Button("Rebuild", role: .destructive) {
                Task { await bootstrapper.rebuildLocalState() }
            }
        } message: {
            Text("Synchronized local content and pending changes will be discarded and rebuilt from Miniflux. Your account and settings are preserved. If synchronization fails, the previous local data cannot be restored.")
        }
        .confirmationDialog("Remove this account?", isPresented: $removalConfirmation) {
            Button("Remove Account", role: .destructive) { Task { await bootstrapper.removeAccount() } }
        } message: {
            Text("Account data and feed preferences on this installation will be removed.")
        }
    }
}

struct StartupView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper

    var body: some View {
        Group {
            switch bootstrapper.state {
            case .starting:
                ProgressView("Starting FluxNews…")
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
