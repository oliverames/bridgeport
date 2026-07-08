import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum SettingsPane: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case connectors = "Connectors"
    case security = "Security"
    case cloudflare = "Cloudflare"
    case cloudConnectors = "Cloud Connectors"
    case onePassword = "1Password"
    case sources = "Sources"

    var id: String { rawValue }

    static func initialSelection(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SettingsPane {
        let requestedFromArguments = arguments.dropFirst().compactMap { argument -> String? in
            guard argument.hasPrefix("--open-settings=") else { return nil }
            return argument.split(separator: "=", maxSplits: 1).last.map(String.init)
        }.first

        guard let requested = requestedFromArguments ?? environment["BRIDGEPORT_SETTINGS_PANE"] else {
            return .dashboard
        }
        let requestedIdentifier = paneIdentifier(requested)
        return allCases.first { paneIdentifier($0.rawValue) == requestedIdentifier } ?? .dashboard
    }

    private static func paneIdentifier(_ value: String) -> String {
        value
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0).lowercased() }
            .joined()
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.bottom.50percent"
        case .connectors: "cable.connector"
        case .security: "lock.shield"
        case .cloudflare: "network"
        case .cloudConnectors: "cloud"
        case .onePassword: "key.viewfinder"
        case .sources: "folder.badge.gearshape"
        }
    }

    var shortcutKey: KeyEquivalent {
        switch self {
        case .dashboard: "1"
        case .connectors: "2"
        case .security: "3"
        case .cloudflare: "4"
        case .cloudConnectors: "5"
        case .onePassword: "6"
        case .sources: "7"
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var selection: SettingsPane = SettingsPane.initialSelection()
    @State private var connectorSearchText = ""
    @State private var deferredSaveTask: Task<Void, Never>?
    @State private var isCloudflareAdvancedExpanded = false
    @FocusState private var connectorSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            .listStyle(.sidebar)
            .settingsSidebarMaterial()
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selection {
                    case .dashboard:
                        dashboardPane
                    case .connectors:
                        connectorsPane
                    case .security:
                        securityPane
                    case .cloudflare:
                        cloudflarePane
                    case .cloudConnectors:
                        cloudConnectorsPane
                    case .onePassword:
                        onePasswordPane
                    case .sources:
                        sourcesPane
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .settingsScrollEdgeTreatment()
            .navigationTitle("Bridgeport Settings")
        }
        .navigationSplitViewStyle(.prominentDetail)
        .settingsToolbarMaterial()
        .frame(minWidth: 860, idealWidth: 980, minHeight: 560, idealHeight: 680)
        .overlay(alignment: .topLeading) {
            keyboardShortcutOverlay
        }
    }

    private var filteredConnectors: [Connector] {
        let query = connectorSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.discoveredConnectors }
        return appState.discoveredConnectors.filter { connector in
            connector.name.localizedCaseInsensitiveContains(query) ||
            connector.configPath.localizedCaseInsensitiveContains(query)
        }
    }

    private var queryTokenFallbackCaption: String {
        "Legacy clients can pass the token in the URL. This same setting appears in Security and Cloud Connectors."
    }

    private var connectorSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find connector", text: $connectorSearchText)
                .textFieldStyle(.plain)
                .focused($connectorSearchFocused)

            if !connectorSearchText.isEmpty {
                Button {
                    connectorSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear connector search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var keyboardShortcutOverlay: some View {
        VStack {
            ForEach(SettingsPane.allCases) { pane in
                Button(pane.rawValue) {
                    selection = pane
                }
                .keyboardShortcut(pane.shortcutKey, modifiers: .command)
            }

            Button("Find Connector") {
                selection = .connectors
                DispatchQueue.main.async {
                    connectorSearchFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func scheduleSave(restartDaemon: Bool = true) {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await appState.save(restartDaemon: restartDaemon)
        }
    }

    private var dashboardPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProductHeader(title: "Bridgeport", subtitle: "Personal MCP gateway for local Mac connectors and self-hosted tools.")

            SettingsGroup(title: "Status") {
                LabeledContent("Daemon") {
                    StatusValue(
                        text: appState.isDaemonRunning ? "Running" : "Stopped",
                        systemImage: appState.isDaemonRunning ? "checkmark.circle.fill" : "stop.circle",
                        tint: appState.isDaemonRunning ? .green : .secondary
                    )
                }
                Divider()
                LabeledContent("Enabled Connectors") {
                    Text("\(appState.enabledConnectorCount) of \(appState.discoveredConnectors.count)")
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("Active Sessions") {
                    Text("\(appState.activeSessionCount)")
                        .foregroundStyle(.secondary)
                }
                Divider()
                LabeledContent("Public Connectors") {
                    Text("\(appState.publicConnectorCount)")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(title: "Service") {
                Text("Refresh status or restart the local Bridgeport daemon.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task {
                        await appState.reload()
                    }
                } label: {
                    Label(appState.isReloading ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isReloading)

                Button {
                    Task {
                        if appState.isDaemonRunning {
                            await appState.restartDaemon()
                        } else {
                            await appState.installDaemon()
                        }
                    }
                } label: {
                    Label(appState.isDaemonRunning ? "Restart Daemon" : "Start Daemon", systemImage: appState.isDaemonRunning ? "arrow.clockwise.circle" : "play.circle")
                }
            }

            SettingsGroup(title: "Endpoints") {
                LabeledContent("Local") {
                    Text("\(appState.localBaseURL)/mcp/<connector>")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Public") {
                    Text(appState.publicBaseURL.isEmpty ? "Not configured" : "\(appState.clientBaseURL)/mcp/<connector>")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(appState.publicBaseURL.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    Text(appState.lastStatusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectorsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Connectors", subtitle: "Enable local MCP servers, expose selected endpoints, and fill required environment values.")
            connectorSearchField

            if appState.discoveredConnectors.isEmpty {
                ContentUnavailableView {
                    Label("No Connectors", systemImage: "cable.connector.slash")
                } description: {
                    Text("Import MCP definitions or mirror Claude Code and Codex to discover local connectors.")
                } actions: {
                    Button("Open Sources") {
                        selection = .sources
                    }
                }
            } else if filteredConnectors.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "magnifyingglass", description: Text("No connectors match the current search."))
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredConnectors, id: \.name) { connector in
                        ConnectorRow(appState: appState, connector: connector)
                    }
                }
            }
        }
    }

    private var securityPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Security", subtitle: "Bridgeport uses bearer-token authentication for local and tunneled MCP traffic.")

            SettingsGroup(title: "Master API Token") {
                LabeledContent("Token") {
                    HStack(spacing: 8) {
                        Text(appState.isShowingToken ? appState.token : String(repeating: "•", count: 28))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(appState.isShowingToken ? "Hide" : "Show") {
                            appState.isShowingToken.toggle()
                        }

                        CopyButton(title: "Copy", systemImage: "doc.on.doc") {
                            appState.token
                        }
                    }
                }
                Divider()
                Button {
                    Task {
                        await appState.rotateToken()
                    }
                } label: {
                    Label("Rotate Token", systemImage: "key.horizontal")
                }
            }

            SettingsGroup(title: "Authentication") {
                Toggle(isOn: $appState.allowQueryTokenAuth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Query-String Token Fallback")
                        Text(queryTokenFallbackCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: appState.allowQueryTokenAuth) {
                    Task { await appState.save() }
                }
            }

            SettingsGroup(title: "Allowed Origins") {
                TextEditor(text: $appState.allowedOriginsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .onChange(of: appState.allowedOriginsText) {
                        scheduleSave()
                    }
            }
        }
    }

    private var cloudflarePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Cloudflare", subtitle: "Create and run a named Cloudflare Tunnel owned by Bridgeport, with explicit per-connector public exposure.")

            SettingsGroup(title: "Status") {
                LabeledContent("Tunnel") {
                    StatusValue(
                        text: appState.cloudflareStatusText,
                        systemImage: cloudflareStatusIcon,
                        tint: cloudflareStatusTint
                    )
                }
                Divider()
                LabeledContent("Detail") {
                    Text(appState.cloudflareStatus.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                LabeledContent("Public URL") {
                    Text(appState.publicBaseURL.isEmpty ? CloudflareManager.publicBaseURL(for: appState.cloudflare) : appState.publicBaseURL)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(appState.cloudflare.hostname.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }

            SettingsGroup(title: "Configuration") {
                Toggle(isOn: $appState.cloudflare.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Cloudflare Tunnel")
                        Text("Bridgeport will manage a local cloudflared LaunchAgent, but connectors are exposed only when their Public toggle is on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: appState.cloudflare.enabled) {
                    Task { await appState.save(restartDaemon: false); await appState.refreshCloudflareStatus() }
                }

                Divider()

                SettingsField(label: "Profile") {
                    TextField("Oliver Ames private", text: $appState.cloudflare.profileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await appState.save(restartDaemon: false) } }
                }

                SettingsField(label: "Domain") {
                    TextField("amesvt.com", text: $appState.cloudflare.domain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await appState.save(restartDaemon: false) } }
                }

                SettingsField(label: "Hostname") {
                    TextField("mcp.amesvt.com", text: $appState.cloudflare.hostname)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            appState.publicBaseURL = CloudflareManager.publicBaseURL(for: appState.cloudflare)
                            Task { await appState.save(restartDaemon: false) }
                        }
                }

                SettingsField(label: "Tunnel Name") {
                    TextField("bridgeport", text: $appState.cloudflare.tunnelName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await appState.save(restartDaemon: false) } }
                }

                DisclosureGroup(isExpanded: $isCloudflareAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsField(label: "Tunnel ID") {
                            TextField("Created or discovered by Bridgeport", text: $appState.cloudflare.tunnelId)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await appState.save(restartDaemon: false) } }
                        }

                        SettingsField(label: "Account ID") {
                            TextField("Optional Cloudflare account ID", text: $appState.cloudflare.accountId)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await appState.save(restartDaemon: false) } }
                        }

                        SettingsField(label: "Zone ID") {
                            TextField("Optional Cloudflare zone ID", text: $appState.cloudflare.zoneId)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await appState.save(restartDaemon: false) } }
                        }

                        SettingsField(label: "cloudflared") {
                            PathEditingField(
                                placeholder: "/opt/homebrew/bin/cloudflared",
                                text: $appState.cloudflare.cloudflaredPath
                            )
                            .onSubmit { Task { await appState.save(restartDaemon: false); await appState.refreshCloudflareStatus() } }
                        }

                        SettingsField(label: "Config File") {
                            PathEditingField(
                                placeholder: "~/.config/bridgeport/cloudflared/config.yml",
                                text: $appState.cloudflare.configFilePath
                            )
                            .onSubmit { Task { await appState.save(restartDaemon: false) } }
                        }

                        SettingsField(label: "Credentials File") {
                            PathEditingField(
                                placeholder: "Created by cloudflared tunnel create",
                                text: $appState.cloudflare.credentialsFilePath
                            )
                            .onSubmit { Task { await appState.save(restartDaemon: false); await appState.refreshCloudflareStatus() } }
                        }

                        SettingsField(label: "Token Env Var") {
                            TextField("CLOUDFLARE_API_TOKEN", text: $appState.cloudflare.apiTokenEnvVar)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await appState.save(restartDaemon: false) } }
                        }

                        SettingsField(label: "Token op:// Ref") {
                            TextField("Optional op://Development/… reference", text: $appState.cloudflare.apiTokenOPReference)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await appState.save(restartDaemon: false) } }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("Advanced Cloudflare Settings", systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ActionGrid(minimumItemWidth: 180) {
                    Button {
                        Task {
                            appState.publicBaseURL = CloudflareManager.publicBaseURL(for: appState.cloudflare)
                            await appState.prepareCloudflareConfiguration()
                        }
                    } label: {
                        Label("Prepare Local Config", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(!appState.cloudflare.enabled)

                    Button {
                        Task { await appState.bootstrapCloudflareTunnel() }
                    } label: {
                        Label("Create or Repair Tunnel", systemImage: "plus.circle")
                    }
                    .disabled(!appState.cloudflare.enabled || !appState.cloudflareStatus.cloudflaredInstalled)

                    Button {
                        Task { await appState.startCloudflareTunnel() }
                    } label: {
                        Label("Start Tunnel", systemImage: "play.circle")
                    }
                    .disabled(!appState.cloudflare.enabled || appState.cloudflareStatus.state == .running)

                    Button {
                        Task { await appState.stopCloudflareTunnel() }
                    } label: {
                        Label("Stop Tunnel", systemImage: "stop.circle")
                    }
                    .disabled(appState.cloudflareStatus.state != .running)

                    Button {
                        Task { await appState.restartCloudflareTunnel() }
                    } label: {
                        Label("Restart Tunnel", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(!appState.cloudflare.enabled || appState.cloudflareStatus.state == .needsTunnel)
                }
            }

            SettingsGroup(title: "Routing") {
                Text("One Cloudflare hostname forwards to \(appState.localBaseURL); only connectors with Public enabled are exposed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                LabeledContent("Route Mode") {
                    Text(appState.cloudflare.routeMode)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Label(
                    appState.cloudflare.createdByBridgeport ? "Bridgeport created this tunnel." : "Bridgeport did not create this tunnel.",
                    systemImage: appState.cloudflare.createdByBridgeport ? "checkmark.circle" : "info.circle"
                )
                .foregroundStyle(.secondary)
            }

            SettingsGroup(title: "Reference") {
                ActionGrid(minimumItemWidth: 180) {
                    Button {
                        openCloudflareDocs()
                    } label: {
                        Label("Open Tunnel Docs", systemImage: "safari")
                    }

                    CopyButton(title: "Copy Public Base URL", systemImage: "doc.on.doc") {
                        CloudflareManager.publicBaseURL(for: appState.cloudflare)
                    }
                    .disabled(appState.cloudflare.hostname.isEmpty)
                }
            }
        }
    }

    private var cloudConnectorsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Cloud Connectors", subtitle: "Copy public Bridgeport endpoints into ChatGPT custom apps, Claude custom connectors, Anthropic API, Mistral Work, and Vibe Code.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Public connector requirements")
                    .font(.headline)
                Text("Each cloud connector needs a public base URL and its Public toggle enabled.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ActionGrid(minimumItemWidth: 190) {
                CopyButton(title: "Copy Cloud Export JSON", systemImage: "doc.on.doc") {
                    appState.cloudConnectorExportJSON()
                }
                .disabled(appState.publicCloudConnectors.isEmpty)

                CopyButton(title: "Copy Vibe TOML", systemImage: "terminal") {
                    appState.allVibeCodeTOML()
                }
                .disabled(appState.publicCloudConnectors.isEmpty)
            }

            SettingsGroup(title: "Compatibility") {
                Toggle(isOn: $appState.allowQueryTokenAuth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Query-String Token Fallback")
                        Text(queryTokenFallbackCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: appState.allowQueryTokenAuth) {
                    Task { await appState.save() }
                }
            }

            if appState.publicBaseURL.isEmpty {
                ContentUnavailableView("Public Base URL Required", systemImage: "globe.badge.chevron.backward", description: Text("Set a Cloudflare-backed public base URL before exporting cloud connector definitions."))
            } else if appState.publicCloudConnectors.isEmpty {
                ContentUnavailableView("No Public Connectors", systemImage: "cloud.slash", description: Text("Enable a connector and turn on its Public toggle to generate cloud connector entries."))
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(appState.publicCloudConnectors, id: \.name) { connector in
                        CloudConnectorRow(appState: appState, connector: connector)
                    }
                }
            }
        }
    }

    private var onePasswordPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "1Password Environment", subtitle: "Resolve connector credentials from a mounted 1Password local .env file plus op:// references.")

            SettingsGroup(title: "Environment") {
                Toggle(isOn: $appState.onePasswordEnvironment.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mounted Local .env File")
                        Text("Use a local 1Password Environment file for connector secrets.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: appState.onePasswordEnvironment.enabled) {
                    Task { await appState.save() }
                }

                Divider()

                SettingsField(label: "Environment") {
                    TextField("Bridgeport", text: $appState.onePasswordEnvironment.environmentName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await appState.save() } }
                        .onChange(of: appState.onePasswordEnvironment.environmentName) {
                            scheduleSave()
                        }
                }

                SettingsField(label: "Account ID") {
                    TextField("1Password account UUID", text: $appState.onePasswordEnvironment.accountId)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await appState.save() } }
                        .onChange(of: appState.onePasswordEnvironment.accountId) {
                            scheduleSave()
                        }
                }

                SettingsField(label: "Environment ID") {
                    TextField("Environment UUID", text: $appState.onePasswordEnvironment.environmentId)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await appState.save() } }
                        .onChange(of: appState.onePasswordEnvironment.environmentId) {
                            scheduleSave()
                        }
                }

                SettingsField(label: "Local .env") {
                    HStack {
                        TextField("~/.config/bridgeport/1password.env", text: $appState.onePasswordEnvironment.localEnvFilePath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await appState.save() } }
                            .onChange(of: appState.onePasswordEnvironment.localEnvFilePath) {
                                scheduleSave()
                            }
                        Button("Choose…") {
                            selectOnePasswordEnvFile()
                        }
                    }
                }

                ActionGrid(minimumItemWidth: 180) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "onepassword://settings/labs")!)
                    } label: {
                        Label("Open 1Password Labs", systemImage: "key")
                    }
                }
            }
        }
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Sources", subtitle: "Import copies MCP definitions into Bridgeport. Mirror keeps reading the external source live.")

            SettingsGroup(title: "Quick Add") {
                ActionGrid(minimumItemWidth: 170) {
                    Button {
                        Task { await appState.mirrorDefaultClaudeCodeMCPs() }
                    } label: {
                        Label("Include Claude Code", systemImage: "sparkles.rectangle.stack")
                    }

                    Button {
                        Task { await appState.mirrorDefaultCodexMCPs() }
                    } label: {
                        Label("Include Codex", systemImage: "terminal")
                    }
                }
            }

            SettingsGroup(title: "Primary Source") {
                SettingsField(label: "Path") {
                    HStack {
                        PathEditingField(
                            placeholder: "Path to MCP plugin directory",
                            text: $appState.connectorsPath
                        )
                        .onSubmit {
                            Task {
                                await appState.save()
                                await appState.reload()
                            }
                        }
                        Button("Choose…") {
                            selectPrimarySource()
                        }
                    }
                }
            }

            SettingsGroup(title: "Mirrored Sources") {
                ActionGrid(minimumItemWidth: 180) {
                    Button {
                        mirrorMCPs()
                    } label: {
                        Label("Mirror MCPs From…", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if appState.mirroredSourcePaths.isEmpty {
                    Text("No mirrored sources yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.mirroredSourcePaths, id: \.self) { path in
                        SourcePathRow(path: path) {
                            Task { await appState.removeMirroredPath(path) }
                        }
                    }
                }
            }

            SettingsGroup(title: "Imported Connectors") {
                Button {
                    importMCPs()
                } label: {
                    Label("Import MCPs", systemImage: "square.and.arrow.down")
                }

                if appState.importedConnectors.isEmpty {
                    Text("No Bridgeport-owned connector definitions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.importedConnectors.keys.sorted(), id: \.self) { name in
                        HStack {
                            Text(name)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Remove") {
                                Task { await appState.removeImportedConnector(name) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func importMCPs() {
        let panel = sourcePanel(title: "Import MCP Definitions")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                _ = await appState.importMCPs(from: url.path)
            }
        }
    }

    private func mirrorMCPs() {
        let panel = sourcePanel(title: "Mirror MCPs From")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.mirrorMCPs(from: url.path)
            }
        }
    }

    private func selectPrimarySource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Primary MCP Source"
        panel.message = "Select the primary MCP plugin directory."
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            appState.connectorsPath = url.path
            Task {
                await appState.save()
                await appState.reload()
            }
        }
    }

    private func selectOnePasswordEnvFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Mounted 1Password .env File"
        panel.message = "Choose the mounted 1Password .env file."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.plainText, .text]

        if panel.runModal() == .OK, let url = panel.url {
            appState.onePasswordEnvironment.localEnvFilePath = url.path
            Task { await appState.save() }
        }
    }

    private func sourcePanel(title: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.message = "Choose a plugin folder or connector settings file."
        panel.prompt = title.localizedCaseInsensitiveContains("Import") ? "Import" : "Mirror"
        panel.allowedContentTypes = sourcePanelContentTypes
        return panel
    }

    private var sourcePanelContentTypes: [UTType] {
        [
            .json,
            .propertyList,
            .plainText,
            UTType(filenameExtension: "toml"),
            UTType(filenameExtension: "mcp")
        ].compactMap { $0 }
    }

    private func openCloudflareDocs() {
        if let url = URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/") {
            NSWorkspace.shared.open(url)
        }
    }

    private var cloudflareStatusTint: Color {
        switch appState.cloudflareStatus.state {
        case .running: .green
        case .error, .missingCloudflared: .red
        case .needsTunnel, .needsConfig: .orange
        case .disabled, .stopped: .secondary
        }
    }

    private var cloudflareStatusIcon: String {
        switch appState.cloudflareStatus.state {
        case .running: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .missingCloudflared: "questionmark.circle"
        case .needsTunnel, .needsConfig: "wrench.and.screwdriver"
        case .stopped: "stop.circle"
        case .disabled: "pause.circle"
        }
    }

}

/// Copy-to-pasteboard button with transient confirmation, per HIG feedback
/// guidance: the label flips to "Copied" briefly so the user knows it worked.
private struct CopyButton: View {
    let title: String
    let systemImage: String
    let value: () -> String?

    @State private var isConfirmingCopy = false

    var body: some View {
        Button {
            guard let value = value(), !value.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            withAnimation { isConfirmingCopy = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                withAnimation { isConfirmingCopy = false }
            }
        } label: {
            Label(isConfirmingCopy ? "Copied" : title, systemImage: isConfirmingCopy ? "checkmark.circle.fill" : systemImage)
        }
    }
}

private struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProductHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 150, alignment: .trailing)
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct PathEditingField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .help(text.isEmpty ? placeholder : text)

            Button {
                revealInFinder(path: text)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
    }
}

private struct PathText: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
            .contextMenu {
                Button("Show in Finder") {
                    revealInFinder(path: path)
                }
            }
    }
}

private struct MonospacedValueText: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(value)
    }
}

private struct RouteValue: View {
    let routePath: String

    var body: some View {
        Text("/mcp/\(routePath)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
            .help("/mcp/\(routePath)")
    }
}

private struct ActionGrid<Content: View>: View {
    let minimumItemWidth: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: 10, alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    @ViewBuilder
    func settingsSidebarMaterial() -> some View {
        self.background(.ultraThinMaterial)
    }

    @ViewBuilder
    func settingsToolbarMaterial() -> some View {
        if #available(macOS 15.0, *) {
            self
                .toolbarBackground(.bar, for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            self
                .toolbarBackground(.bar, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
    }

    @ViewBuilder
    func settingsScrollEdgeTreatment() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

private func revealInFinder(path: String) {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let expanded = NSString(string: trimmed).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardizedFileURL
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusValue: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(tint)
    }
}

private struct ConnectorRow: View {
    @Bindable var appState: AppState
    let connector: Connector

    var body: some View {
        let settings = appState.connectorSettings(for: connector.name)
        let activeCount = appState.activeSessions(for: connector)
        let isPublic = settings.exposePublicly
        let routePath = effectiveRoutePath(settings: settings)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ActivityIndicator(isActive: activeCount > 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.headline)
                        .lineLimit(1)
                    PathText(path: connector.configPath)
                }

                Spacer()

                StatusLine(text: connector.sourceKind.rawValue.capitalized, systemImage: connector.sourceKind == .imported ? "square.and.arrow.down" : "arrow.triangle.2.circlepath")
                StatusLine(text: activeCount == 1 ? "1 session" : "\(activeCount) sessions", systemImage: "dot.radiowaves.left.and.right")

                Toggle(isOn: Binding(
                    get: { appState.connectorSettings(for: connector.name).enabled },
                    set: { _ in Task { await appState.toggleConnector(connector.name) } }
                )) {
                    Text("Enable \(connector.name)")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Enable \(connector.name)")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle("Public", isOn: Binding(
                        get: { appState.connectorSettings(for: connector.name).exposePublicly },
                        set: { _ in Task { await appState.togglePublicExposure(connector.name) } }
                    ))

                    Label("Route", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .foregroundStyle(.secondary)

                    RouteValue(routePath: routePath)

                    if isPublic {
                        TextField("Custom route", text: Binding(
                            get: { appState.connectorSettings(for: connector.name).publicPath ?? "" },
                            set: { newValue in
                                var settings = appState.connectorSettings(for: connector.name)
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                settings.publicPath = trimmed.isEmpty ? nil : newValue
                                appState.connectorSettings[connector.name] = settings
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit {
                            Task {
                                await appState.setPublicPath(appState.connectorSettings(for: connector.name).publicPath ?? "", for: connector.name)
                            }
                        }
                    }
                }

                ActionGrid(minimumItemWidth: 138) {
                    CopyButton(title: "Copy Local", systemImage: "link") {
                        appState.endpointURL(for: connector, publicEndpoint: false)
                    }

                    if isPublic && !appState.publicBaseURL.isEmpty {
                        CopyButton(title: "Copy Public", systemImage: "globe") {
                            appState.endpointURL(for: connector, publicEndpoint: true)
                        }
                    }
                }
            }

            let requiredVars = connector.requiredEnvVarNames
            if !requiredVars.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(requiredVars, id: \.self) { varName in
                            HStack {
                                Text(varName)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 220, alignment: .trailing)
                                if isSensitiveKey(varName) {
                                    SecureField("op:// reference or value", text: envBinding(varName))
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    TextField("op:// reference or value", text: envBinding(varName))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        HStack {
                            Spacer()
                                .frame(width: 220)
                            Button {
                                Task { await appState.save() }
                            } label: {
                                Label("Apply Environment", systemImage: "checkmark.circle")
                            }
                        }
                    }
                } label: {
                    Label("Required Environment (\(requiredVars.count))", systemImage: "key")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func envBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { appState.env[name] ?? "" },
            set: { newValue in
                appState.env[name] = newValue
            }
        )
    }

    private func isSensitiveKey(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("token") || lower.contains("key") || lower.contains("secret") || lower.contains("password")
    }

    private func effectiveRoutePath(settings: BridgeportConnectorSettings) -> String {
        let configuredPath = settings.publicPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeSource = configuredPath.flatMap { $0.isEmpty ? nil : $0 } ?? connector.name
        return ConfigManager.normalizedRoutePath(routeSource)
    }
}

private struct SourcePathRow: View {
    let path: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sourceIcon)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            PathText(path: path)

            Spacer()

            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sourceIcon: String {
        path.hasSuffix(".toml") || path.hasSuffix(".json") ? "doc.text" : "folder"
    }
}

private struct ActivityIndicator: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: isActive ? "dot.radiowaves.left.and.right" : "circle")
            .foregroundStyle(isActive ? .green : .secondary)
            .frame(width: 18)
            .help(isActive ? "Active session" : "No active sessions")
            .accessibilityLabel(isActive ? "Active session" : "No active sessions")
    }
}

private struct StatusLine: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct CloudConnectorRow: View {
    @Bindable var appState: AppState
    let connector: Connector

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "cloud")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.headline)
                    MonospacedValueText(value: appState.endpointURL(for: connector, publicEndpoint: true))
                }
                Spacer()
            }

            ActionGrid(minimumItemWidth: 190) {
                CopyButton(title: "Copy Claude URL", systemImage: "sparkles") {
                    appState.claudeCustomConnectorURL(for: connector)
                }
                .disabled(appState.claudeCustomConnectorURL(for: connector) == nil)

                CopyButton(title: "Copy ChatGPT URL", systemImage: "bubble.left.and.text.bubble.right") {
                    appState.chatGPTCustomAppURL(for: connector)
                }
                .disabled(appState.chatGPTCustomAppURL(for: connector) == nil)

                CopyButton(title: "Copy Anthropic JSON", systemImage: "curlybraces") {
                    appState.anthropicMessagesAPIJSON(for: connector)
                }

                CopyButton(title: "Copy Mistral JSON", systemImage: "square.grid.2x2") {
                    appState.mistralCustomConnectorJSON(for: connector)
                }

                CopyButton(title: "Copy Vibe TOML", systemImage: "terminal") {
                    appState.vibeCodeTOML(for: connector)
                }
            }

            DisclosureGroup {
                ConnectorSetupGuide(appState: appState, connector: connector)
            } label: {
                Text("Step-by-Step Setup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(appState.allowQueryTokenAuth ? "Claude uses Bridgeport OAuth. ChatGPT and Codex can use OAuth or the private query-token fallback for compatibility testing. Anthropic API, Mistral, and Vibe should use Bearer auth." : "Claude uses Bridgeport OAuth. ChatGPT and Codex use OAuth as the production path. Anthropic API, Mistral, and Vibe exports use Bearer auth.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Numbered, provider-specific instructions so connecting a Bridgeport MCP to
/// a web client is a paste-and-click flow, with every needed value one copy
/// button away.
private struct ConnectorSetupGuide: View {
    @Bindable var appState: AppState
    let connector: Connector

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GuideSection(
                title: "Claude (claude.ai, desktop, and mobile)",
                steps: [
                    "In Claude, open Settings > Connectors and choose Add custom connector.",
                    "Name the connector and paste the MCP URL, then choose Add.",
                    "Choose Connect. Bridgeport's approval page opens; paste your Bridgeport token and choose Authorize."
                ]
            ) {
                CopyButton(title: "Copy MCP URL", systemImage: "link") {
                    appState.claudeCustomConnectorURL(for: connector)
                }
                CopyButton(title: "Copy Bridgeport Token", systemImage: "key") {
                    appState.token
                }
            }

            GuideSection(
                title: "ChatGPT and Codex (web)",
                steps: [
                    "In ChatGPT, open Settings > Connectors and enable Developer mode, then choose Create. Codex on the web uses the same connectors.",
                    "Name the connector and paste the MCP URL.",
                    appState.allowQueryTokenAuth
                        ? "The copied URL carries the query-token fallback for private compatibility testing."
                        : "Production ChatGPT connectors need OAuth; the query-token fallback is currently off."
                ]
            ) {
                CopyButton(title: "Copy MCP URL", systemImage: "link") {
                    appState.chatGPTCustomAppURL(for: connector)
                }
            }

            GuideSection(
                title: "Mistral (Le Chat and Work)",
                steps: [
                    "In Le Chat, open Connectors and add a custom MCP connector.",
                    "Paste the MCP URL, set Authentication to HTTP Bearer Token, and paste the header value.",
                    "For branded connector-card artwork, create the connector from the Mistral JSON payload instead; it carries Bridgeport's icon URL."
                ]
            ) {
                CopyButton(title: "Copy MCP URL", systemImage: "link") {
                    appState.endpointURL(for: connector, publicEndpoint: true)
                }
                CopyButton(title: "Copy Bearer Header", systemImage: "key.horizontal") {
                    appState.bearerHeaderValue
                }
                CopyButton(title: "Copy Mistral JSON", systemImage: "curlybraces") {
                    appState.mistralCustomConnectorJSON(for: connector)
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct GuideSection<Actions: View>: View {
    let title: String
    let steps: [String]
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ActionGrid(minimumItemWidth: 170) {
                actions
            }
            .controlSize(.small)
        }
    }
}
