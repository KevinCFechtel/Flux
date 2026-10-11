import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSection: String, CaseIterable, Identifiable {
    case account
    case articles
    case navigation
    case media
    case backgroundSync
    case systemNotifications
    case general
    case configurationBackup

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .account: "Account"
        case .articles: "Articles"
        case .navigation: "Navigation"
        case .media: "Media"
        case .backgroundSync: "Background Sync"
        case .systemNotifications: "System Notifications"
        case .general: "General"
        case .configurationBackup: "Configuration Backup"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .articles: "doc.text"
        case .navigation: "sidebar.leading"
        case .media: "headphones"
        case .backgroundSync: "arrow.triangle.2.circlepath"
        case .systemNotifications: "bell"
        case .general: "gearshape"
        case .configurationBackup: "externaldrive.badge.timemachine"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @State private var server = ""
    @State private var key = ""
    @State private var customHeaders: [CustomHTTPHeader] = []
    @State private var scrollover = true
    @State private var syncOnStart = true
    @State private var launchAtLogin = false
    @State private var globalShortcut = GlobalShortcutChoice.optionCommandF
    @State private var section: SettingsSection = .account
    @State private var settingsSidebarVisible = true
    @State private var backupFlow: BackupPasswordFlow?
    @State private var settingsWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("FluxNews Settings")
                    .font(.title2.bold())

                Button {
                    settingsSidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help(settingsSidebarVisible ? "Hide navigation" : "Show navigation")
                .accessibilityLabel(settingsSidebarVisible ? "Hide navigation" : "Show navigation")

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            HStack(spacing: 0) {
                if settingsSidebarVisible {
                    SettingsSidebar(selection: $section)
                        .frame(width: 170)
                        .overlay(alignment: .trailing) { Divider() }
                }

                ScrollView {
                    settingsPage
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button { settingsWindow?.performClose(nil) } label: {
                    if section == .account { Text("Cancel") } else { Text("Done") }
                }
                if section == .account {
                    Button { store.saveAccount(server: server.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), customHeaders: customHeaders, launchAtLogin: launchAtLogin, scrollover: scrollover, syncOnStart: syncOnStart, globalShortcut: globalShortcut) } label: {
                        if store.isSavingAccount { Text("Validating…") } else { Text("Save") }
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(server.isEmpty || key.isEmpty || store.isSavingAccount)
                }
            }
                .padding(16)
        }
        .frame(minWidth: 640, minHeight: 420)
        .overlay(alignment: .bottom) {
            if let confirmation = store.actionConfirmation {
                Text(confirmation)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .padding(.bottom, 16)
            }
        }
        .background(SettingsWindowReader { window in
            guard settingsWindow !== window else { return }
            settingsWindow = window
        })
        .sheet(item: $backupFlow) { flow in
            BackupPasswordSheet(flow: flow, submit: { password in
                switch flow {
                case let .export(url):
                    do {
                        try await store.exportConfigurationBackup(password: password).write(to: url, options: .atomic)
                        store.showActionConfirmation("Configuration backup exported")
                        return .success()
                    } catch {
                        return .failure(NativeErrorPresentation.message(for: error))
                    }
                case let .importBackup(data):
                    do {
                        let outcome = try await store.importConfigurationBackup(bytes: data, password: password)
                        return .success(outcome.confirmationMessage)
                    } catch {
                        return .failure(backupImportErrorMessage(error))
                    }
                }
            }, onSuccess: { message in
                store.showActionConfirmation(message)
            })
        }
        .onAppear {
            if let credentials = try? CredentialStore.load() { server = credentials.server; key = credentials.apiKey; customHeaders = credentials.resolvedCustomHeaders }
            launchAtLogin = CredentialStore.launchAtLoginEnabled
            scrollover = store.markReadOnScrolloverEnabled
            syncOnStart = store.syncOnStartEnabled
            globalShortcut = store.globalShortcut
        }
    }
    @ViewBuilder private var settingsPage: some View {
        switch section {
        case .account:
            AccountSettingsView(server: $server, key: $key, customHeaders: $customHeaders, configuredServer: store.configuredServer, version: store.minifluxVersion, validationError: store.accountValidationError)
        case .articles:
            MacOSArticlesSettingsView(
                store: store,
                scrollover: $scrollover,
                retention: retention,
                deliveryMode: deliveryMode,
                detailCharacterLimit: detailCharacterLimit
            )
        case .navigation:
            MacOSNavigationSettingsView(store: store)
        case .media:
            MediaSettingsView(store: store, autoDownloadListeningList: autoDownloadListeningList, deleteAfterPlayback: deleteAfterPlayback, removeCompletedListeningList: removeCompletedListeningList)
        case .backgroundSync:
            MacOSBackgroundSyncSettingsView(
                store: store,
                syncOnStart: $syncOnStart,
                backgroundSyncEnabled: backgroundSyncEnabled
            )
        case .systemNotifications:
            SystemNotificationsSettingsView(store: store)
        case .general:
            GeneralSettingsView(launchAtLogin: $launchAtLogin, globalShortcut: $globalShortcut, registrationError: store.globalShortcutRegistrationError)
        case .configurationBackup:
            DataBackupSettingsView(store: store, export: chooseExportDestination, importBackup: chooseImportSource, filePanelsAvailable: settingsWindow != nil)
        }
    }
    private var retention: Binding<ReadArticleRetention> {
        Binding(
            get: { store.coreSettings?.retention ?? .days90 },
            set: { store.setRetention($0) }
        )
    }
    private var deliveryMode: Binding<DeliveryMode> {
        Binding(
            get: { store.coreSettings?.deliveryMode ?? .deferred },
            set: { store.setDeliveryMode($0) }
        )
    }
    private var backgroundSyncEnabled: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.backgroundSyncEnabled ?? false },
            set: { store.setBackgroundSyncEnabled($0) }
        )
    }
    private var autoDownloadListeningList: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.autoDownloadListeningList ?? false },
            set: { store.setAutoDownloadListeningList($0) }
        )
    }
    private var deleteAfterPlayback: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.deleteAfterPlayback ?? false },
            set: { store.setDeleteAfterPlayback($0) }
        )
    }
    private var removeCompletedListeningList: Binding<Bool> {
        Binding(
            get: { store.coreSettings?.removeCompletedListeningList ?? false },
            set: { store.setRemoveCompletedListeningList($0) }
        )
    }
    private var detailCharacterLimit: Binding<UInt32> {
        Binding(
            get: { store.coreSettings?.detailCharacterLimit ?? 10_000 },
            set: { store.setDetailCharacterLimit($0) }
        )
    }
    private func chooseExportDestination() {
        guard let settingsWindow, settingsWindow.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fluxbackup") ?? .data]
        panel.nameFieldStringValue = "FluxNews Backup.fluxbackup"
        panel.beginSheetModal(for: settingsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            // AppKit must finish detaching its sheet before SwiftUI presents the password sheet.
            DispatchQueue.main.async { backupFlow = .export(url) }
        }
    }
    private func chooseImportSource() {
        guard let settingsWindow, settingsWindow.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fluxbackup") ?? .data]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: settingsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                // AppKit must finish detaching its sheet before SwiftUI presents the password sheet.
                DispatchQueue.main.async { backupFlow = .importBackup(data) }
            } catch {
                store.errorMessage = NativeErrorPresentation.message(for: error)
            }
        }
    }
}

private struct SettingsWindowReader: NSViewRepresentable {
    let onWindowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> SettingsWindowReportingView {
        SettingsWindowReportingView(onWindowChanged: onWindowChanged)
    }

    func updateNSView(_ view: SettingsWindowReportingView, context: Context) {
        view.onWindowChanged = onWindowChanged
        onWindowChanged(view.window)
    }
}

private final class SettingsWindowReportingView: NSView {
    var onWindowChanged: (NSWindow?) -> Void

    init(onWindowChanged: @escaping (NSWindow?) -> Void) {
        self.onWindowChanged = onWindowChanged
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged(window)
    }
}

private enum BackupPasswordFlow: Identifiable {
    case export(URL)
    case importBackup(Data)
    var id: String { switch self { case .export: "export"; case .importBackup: "import" } }
    var isExport: Bool { if case .export = self { true } else { false } }
}

private struct BackupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let flow: BackupPasswordFlow
    let submit: (String) async -> BackupPasswordSubmissionResult
    let onSuccess: (String) -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var submission = BackupPasswordSubmissionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if flow.isExport { Text("Encrypt Configuration Backup") }
                else { Text("Import Configuration Backup") }
            }
                .font(.title2.bold())
            SecureField("Backup Password", text: $password)
            if flow.isExport { SecureField("Confirm Password", text: $confirmation) }
            if submission.isProcessing { ProgressView().controlSize(.small) }
            if let error = submission.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("FluxNews cannot recover this password.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(submission.isProcessing)
                Button { perform() } label: {
                    if submission.isProcessing { Text("Processing…") }
                    else if flow.isExport { Text("Export") }
                    else { Text("Import") }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submission.isProcessing)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: password) { _, _ in submission.clearError() }
        .onChange(of: confirmation) { _, _ in submission.clearError() }
    }
    private func perform() {
        guard submission.begin(isExport: flow.isExport, password: password, confirmation: confirmation) else { return }
        Task {
            switch await submit(password) {
            case let .success(confirmation):
                guard submission.complete(error: nil) else { return }
                dismiss()
                if let confirmation {
                    DispatchQueue.main.async { onSuccess(confirmation) }
                }
            case let .failure(error):
                _ = submission.complete(error: error)
            }
        }
    }
}

private struct DataBackupSettingsView: View {
    @ObservedObject var store: BrowserStore
    let export: () -> Void
    let importBackup: () -> Void
    let filePanelsAvailable: Bool
    @State private var confirmRebuild = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Configuration Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Export or import your account, FluxNews settings, Feed Settings, and macOS preferences. Configuration backups are password encrypted.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export Configuration Backup...") { export() }
                        Button("Import Configuration Backup...") { importBackup() }
                    }
                    .disabled(!filePanelsAvailable)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Destructive Operations") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Rebuild Local State...") { confirmRebuild = true }
                    Text("Discard synchronized local content. Miniflux becomes authoritative again; FluxNews and Feed Settings are preserved. Unsynchronized Read or Star changes may be lost.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button("Reset FluxNews...") { confirmReset = true }.foregroundStyle(.red)
                    Text("Remove the configured account, API key, Core and Feed Settings, local data, and FluxNews preferences.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            Spacer()
        }
        .alert("Rebuild Local State?", isPresented: $confirmRebuild) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild", role: .destructive) { store.rebuildLocalState() }
        } message: { Text("Synchronized local content will be discarded and Miniflux will become authoritative again. FluxNews and Feed Settings are preserved.") }
        .alert("Reset FluxNews?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { store.resetFluxNews() }
        } message: { Text("This removes your account, API key, settings, Feed Settings, and local data. FluxNews will return to its first-run state.") }
    }
}

private func backupImportErrorMessage(_ error: Error) -> String {
    switch error {
    case ConfigBackupError.NotFluxBackup: "Not a valid FluxNews backup."
    case ConfigBackupError.PlatformMismatch: "This backup was created for another platform."
    case ConfigBackupError.UnsupportedVersion: "This backup uses a newer unsupported format."
    case ConfigBackupError.DecryptionFailed: "The backup could not be decrypted. The password may be incorrect or the file may be damaged."
    default: String(localized: "The backup could not be imported. Please try again.")
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        List {
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .foregroundStyle(section == selection ? .white : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .listRowBackground(section == selection ? Color.accentColor : .clear)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct AccountSettingsView: View {
    @Binding var server: String
    @Binding var key: String
    @Binding var customHeaders: [CustomHTTPHeader]
    let configuredServer: String?
    let version: String?
    let validationError: String?
    @State private var revealedHeaderIDs = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                  GridRow {
                      Text("Miniflux Server")
                          .frame(width: 140, alignment: .leading)

                      TextField("", text: $server)
                          .textFieldStyle(.roundedBorder)
                          .frame(maxWidth: .infinity)
                  }

                  GridRow {
                      Text("API Key")
                          .frame(width: 140, alignment: .leading)

                      SecureField("", text: $key)
                          .textFieldStyle(.roundedBorder)
                          .frame(maxWidth: .infinity)
                  }
              }
              .frame(maxWidth: .infinity, alignment: .leading)



            GroupBox("Custom HTTP Headers") {
                customHeadersEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                LabeledContent("Miniflux") { Text(version ?? "—").foregroundStyle(.secondary) }
                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("API keys and custom header values are stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: configuredServer) { _, server in
            if let server { self.server = server }
        }
        .onAppear { revealedHeaderIDs = [] }
    }

    private var customHeadersEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(customHeaders.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Header Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            revealedHeaderIDs.remove(customHeaders[index].id)
                            customHeaders.remove(at: index)
                        }
                        .buttonStyle(.borderless)
                    }

                    TextField("", text: $customHeaders[index].name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)

                    Text("Value")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        headerValueField(at: index)
                            .frame(maxWidth: .infinity)

                        Button {
                            toggleHeaderValueVisibility(for: customHeaders[index].id)
                        } label: {
                            Image(systemName: revealedHeaderIDs.contains(customHeaders[index].id) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealedHeaderIDs.contains(customHeaders[index].id) ? String(localized: "Hide header value") : String(localized: "Show header value"))
                        .accessibilityLabel(revealedHeaderIDs.contains(customHeaders[index].id) ? String(localized: "Hide header value") : String(localized: "Show header value"))
                        .frame(width: 24)
                    }
                }

                if index < customHeaders.count - 1 {
                    Divider()
                }
            }

            Button { customHeaders.append(CustomHTTPHeader()) } label: {
                Label("Add Header", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headerValueField(at index: Int) -> some View {
        if revealedHeaderIDs.contains(customHeaders[index].id) {
            TextField("", text: $customHeaders[index].value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        } else {
            SecureField("", text: $customHeaders[index].value)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        }
    }

    private func toggleHeaderValueVisibility(for id: UUID) {
        if revealedHeaderIDs.contains(id) {
            revealedHeaderIDs.remove(id)
        } else {
            revealedHeaderIDs.insert(id)
        }
    }
}

private struct MacOSArticlesSettingsView: View {
    @ObservedObject var store: BrowserStore
    @Binding var scrollover: Bool
    let retention: Binding<ReadArticleRetention>
    let deliveryMode: Binding<DeliveryMode>
    let detailCharacterLimit: Binding<UInt32>

    var body: some View {
        Form {
            Picker("Open article", selection: Binding(get: { store.clickOnNews }, set: store.setClickOnNews)) {
                Text("Original link").tag(ClickOnNews.openLink)
                Text("Reader").tag(ClickOnNews.openDetailView)
            }
            Picker("Presentation", selection: Binding(get: { store.articlePresentationMode }, set: store.setArticlePresentationMode)) {
                ForEach(ArticlePresentationMode.allCases, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.displayNameKey)).tag(mode)
                }
            }
            Picker("Preview lines", selection: Binding(get: { store.articlePreviewLines }, set: store.setArticlePreviewLines)) {
                Text("2 lines").tag(ArticlePreviewLines.compact)
                Text("3 lines").tag(ArticlePreviewLines.standard)
                Text("5 lines").tag(ArticlePreviewLines.extended)
            }
            Toggle("Show article count", isOn: Binding(get: { store.showArticleCount }, set: store.setShowArticleCount))
            Toggle("Show relative publication time", isOn: Binding(get: { store.showRelativePublicationTime }, set: store.setShowRelativePublicationTime))
            Toggle("Remove articles when read", isOn: Binding(get: { store.removeArticlesWhenMarkedRead }, set: store.setRemoveArticlesWhenMarkedRead))
            Toggle(
                "Mark read on scrollover",
                isOn: Binding(
                    get: { store.markReadOnScrolloverEnabled },
                    set: { enabled in
                        scrollover = enabled
                        store.setScrolloverEnabled(enabled)
                    }
                )
            )

            Section {
                Picker("Keep read articles", selection: retention) {
                    Text("30 days").tag(ReadArticleRetention.days30)
                    Text("60 days").tag(ReadArticleRetention.days60)
                    Text("90 days").tag(ReadArticleRetention.days90)
                    Text("180 days").tag(ReadArticleRetention.days180)
                    Text("365 days").tag(ReadArticleRetention.days365)
                }
                Picker("Reader detail limit", selection: detailCharacterLimit) {
                    Text("5,000 characters").tag(UInt32(5_000))
                    Text("10,000 characters").tag(UInt32(10_000))
                    Text("20,000 characters").tag(UInt32(20_000))
                }
            } header: {
                Text("Storage & Reader")
            } footer: {
                Text("Read article retention controls how long synchronized read items remain in local history. The Reader detail limit controls how much article text the Core keeps when a feed uses truncated Reader content.")
            }
            .disabled(store.coreSettings == nil)

            Section {
                Picker(
                    "Sync article changes",
                    selection: deliveryMode
                ) {
                    Text("Deferred").tag(DeliveryMode.deferred)
                    Text("Immediately").tag(DeliveryMode.live)
                }
                .disabled(store.coreSettings == nil)
            } footer: {
                Text("Immediate delivery saves read/unread and star changes locally first and then sends them to Miniflux. Failed delivery remains pending for a later retry.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacOSNavigationSettingsView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        Form {
            Toggle(
                "Hide empty feeds",
                isOn: Binding(
                    get: { store.hideEmptyNavigationEntries },
                    set: store.setHideEmptyNavigationEntries
                )
            )
            Picker(
                "Startup scope",
                selection: Binding(get: { store.startupScope }, set: store.setStartupScope)
            ) {
                Text("All News").tag(StartupScopePreference.allNews)
                Text("Starred").tag(StartupScopePreference.starred)
                Text("Category").tag(StartupScopePreference.category)
                Text("Feed").tag(StartupScopePreference.feed)
            }
            if store.startupScope == .category {
                Picker(
                    "Startup category",
                    selection: Binding(
                        get: { store.startupCategoryID },
                        set: store.setStartupCategoryID
                    )
                ) {
                    ForEach(store.catalog.categories, id: \.id) { category in
                        Text(category.title).tag(Optional(category.id))
                    }
                }
                .disabled(store.catalog.categories.isEmpty)
            }
            if store.startupScope == .feed {
                Picker(
                    "Startup feed",
                    selection: Binding(
                        get: { store.startupFeedID },
                        set: store.setStartupFeedID
                    )
                ) {
                    ForEach(store.catalog.feeds, id: \.id) { feed in
                        Text(feed.title).tag(Optional(feed.id))
                    }
                }
                .disabled(store.catalog.feeds.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacOSBackgroundSyncSettingsView: View {
    @ObservedObject var store: BrowserStore
    @Binding var syncOnStart: Bool
    let backgroundSyncEnabled: Binding<Bool>

    var body: some View {
        Form {
            Section {
                Toggle("Background Sync", isOn: backgroundSyncEnabled)
                    .disabled(store.coreSettings == nil)
                Toggle("Sync on Start", isOn: $syncOnStart)
            } footer: {
                Text("When enabled, FluxNews may refresh news in the background and when you return to the app. Manual Sync remains available at all times.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MediaSettingsView: View {
    @ObservedObject var store: BrowserStore
    let autoDownloadListeningList: Binding<Bool>
    let deleteAfterPlayback: Binding<Bool>
    let removeCompletedListeningList: Binding<Bool>

    var body: some View {
        Form {
            Section("Listening List") {
                Toggle("Automatically download Listening List audio", isOn: autoDownloadListeningList)
                Text("Downloads audio automatically when an item is added to Listening List.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Delete download after playback completes", isOn: deleteAfterPlayback)
                Text("Removes the local download after playback is completed. The item remains in Listening List.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove completed items from Listening List", isOn: removeCompletedListeningList)
                Text("Removes the item from Listening List after all of its audio has been completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(store.coreSettings == nil)
        }
        .formStyle(.grouped)
    }
}

struct FeedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BrowserStore
    let target: FeedSettingsTarget
    @State private var preferences: FeedPreferences?
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Feed Settings").font(.title2.bold())
            Text(target.title).foregroundStyle(.secondary)
            if let preferences {
                Form {
                    Picker("Detail Rendering", selection: Binding(get: { preferences.detailRendering }, set: updateDetailRendering)) {
                        Text("Rendered").tag(DetailRenderingMode.rendered)
                        Text("Text Only").tag(DetailRenderingMode.textOnly)
                    }
                     Toggle("Truncate Detail", isOn: Binding(get: { preferences.truncateDetail }, set: updateTruncateDetail))
                     Toggle(
                        "System Notifications",
                        isOn: Binding(
                            get: { preferences.systemNotificationsEnabled },
                            set: updateSystemNotifications
                        )
                     )
                     Toggle("Open in Miniflux", isOn: Binding(get: { preferences.openInMiniflux }, set: updateOpenInMiniflux))
                     Toggle("Automatically download audio from this feed", isOn: Binding(get: { preferences.autoDownloadAudio }, set: updateAutoDownloadAudio))
                 }
                .disabled(isSaving)
                .formStyle(.grouped)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear(perform: load)
    }

    private func load() {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else { dismiss(); return }
        store.loadFeedPreferences(feedID: target.id) { result in
            switch result {
            case let .success(value):
                preferences = value
                error = nil
            case let .failure(loadError):
                error = NativeErrorPresentation.message(for: loadError)
            }
        }
    }

    private func applyPreferenceUpdate(
        _ operation: (@escaping (Result<FeedPreferences, Error>) -> Void) -> Void
    ) {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else {
            dismiss()
            return
        }
        isSaving = true
        error = nil
        operation { result in
            isSaving = false
            switch result {
            case let .success(value):
                preferences = value
            case let .failure(updateError):
                error = NativeErrorPresentation.message(for: updateError)
            }
        }
    }

    private func updateDetailRendering(_ mode: DetailRenderingMode) {
        applyPreferenceUpdate { completion in
            store.setFeedDetailRendering(feedID: target.id, mode: mode, completion: completion)
        }
    }

    private func updateTruncateDetail(_ enabled: Bool) {
        applyPreferenceUpdate { completion in
            store.setFeedTruncateDetail(feedID: target.id, enabled: enabled, completion: completion)
        }
    }
    private func updateSystemNotifications(_ enabled: Bool) {
        guard store.catalog.feeds.contains(where: { $0.id == target.id }) else {
            dismiss()
            return
        }
        isSaving = true
        error = nil
        store.setSystemNotificationsEnabled(feedID: target.id, enabled: enabled) { result in
            isSaving = false
            switch result {
            case .success:
                load()
            case let .failure(error):
                self.error = NativeErrorPresentation.message(for: error)
            }
        }
    }

    private func updateOpenInMiniflux(_ enabled: Bool) {
        applyPreferenceUpdate { completion in
            store.setFeedOpenInMiniflux(feedID: target.id, enabled: enabled, completion: completion)
        }
    }

    private func updateAutoDownloadAudio(_ enabled: Bool) {
        applyPreferenceUpdate { completion in
            store.setFeedAutoDownloadAudio(feedID: target.id, enabled: enabled, completion: completion)
        }
    }
}

private struct SystemNotificationsSettingsView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Notifications").font(.title2.bold())
            Text("Choose which feeds may send macOS notifications.")
                .foregroundStyle(.secondary)
            if let error = store.systemNotificationSettingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if store.systemNotificationSettings.isEmpty {
                ContentUnavailableView("No feeds available.", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.systemNotificationSettings, id: \.feedId) { setting in
                    Toggle(setting.feedTitle, isOn: Binding(
                        get: { setting.systemNotificationsEnabled },
                        set: { store.setSystemNotificationsEnabled(feedID: setting.feedId, enabled: $0) }
                    ))
                    .disabled(store.updatingSystemNotificationFeedIDs.contains(setting.feedId))
                }
                .listStyle(.inset)
            }
            Spacer()
        }
        .onAppear { store.reloadSystemNotificationSettings() }
    }
}

private struct GeneralSettingsView: View {
    @Binding var launchAtLogin: Bool
    @Binding var globalShortcut: GlobalShortcutChoice
    let registrationError: String?

    var body: some View {
        Form {
            Toggle("Launch automatically at login", isOn: $launchAtLogin)
            Picker("Global shortcut", selection: $globalShortcut) {
                ForEach(GlobalShortcutChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let registrationError {
                Text(registrationError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}
