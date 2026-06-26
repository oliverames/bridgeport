import SwiftUI
import AppKit

private enum SettingsPane: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case connectors = "Connectors"
    case security = "Security"
    case cloudflare = "Cloudflare"
    case cloudConnectors = "Cloud Connectors"
    case onePassword = "1Password"
    case sources = "Sources"

    var id: String { rawValue }

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
}

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var selection: SettingsPane? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selection ?? .dashboard {
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
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
        }
        .frame(width: 980, height: 680)
    }

    private var dashboardPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Bridgeport", subtitle: "Personal MCP gateway for local Mac connectors and self-hosted tools.")

            HStack(spacing: 12) {
                MetricView(title: "Daemon", value: appState.isDaemonRunning ? "Running" : "Stopped", systemImage: appState.isDaemonRunning ? "checkmark.circle.fill" : "stop.circle")
                MetricView(title: "Enabled", value: "\(appState.enabledConnectorCount)/\(appState.discoveredConnectors.count)", systemImage: "switch.2")
                MetricView(title: "Active Sessions", value: "\(appState.activeSessionCount)", systemImage: "dot.radiowaves.left.and.right")
                MetricView(title: "Public", value: "\(appState.publicConnectorCount)", systemImage: "globe")
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        appState.checkDaemonStatus()
                        await appState.refreshDaemonRuntimeStatus()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

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

                Button {
                    selection = .sources
                    importMCPs()
                } label: {
                    Label("Import MCPs", systemImage: "square.and.arrow.down")
                }

                Button {
                    selection = .sources
                    mirrorMCPs()
                } label: {
                    Label("Mirror MCPs From...", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Endpoints")
                    .font(.headline)
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

            if appState.discoveredConnectors.isEmpty {
                ContentUnavailableView("No Connectors", systemImage: "cable.connector.slash", description: Text("Import MCPs or mirror a source to discover local connectors."))
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(appState.discoveredConnectors, id: \.name) { connector in
                        ConnectorRow(appState: appState, connector: connector)
                    }
                }
            }
        }
    }

    private var securityPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Security", subtitle: "Bridgeport uses bearer-token authentication for local and tunneled MCP traffic.")

            VStack(alignment: .leading, spacing: 10) {
                Text("Master API Token")
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(appState.isShowingToken ? appState.token : String(repeating: "•", count: 28))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

                    Button(appState.isShowingToken ? "Hide" : "Show") {
                        appState.isShowingToken.toggle()
                    }

                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(appState.token, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

                HStack {
                    Button {
                        Task {
                            await appState.rotateToken()
                        }
                    } label: {
                        Label("Rotate Token", systemImage: "key.horizontal")
                    }

                    Toggle("Allow query-string token fallback", isOn: $appState.allowQueryTokenAuth)
                        .onChange(of: appState.allowQueryTokenAuth) {
                            Task { await appState.save() }
                        }
                }

                Text("Header auth is preferred. Query-string fallback is only for legacy MCP clients that cannot send Authorization headers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Allowed Origins")
                    .font(.headline)
                TextEditor(text: $appState.allowedOriginsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                Button {
                    Task { await appState.save() }
                } label: {
                    Label("Save Origins", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var cloudflarePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Cloudflare", subtitle: "Use Cloudflare Tunnel to route a private hostname to Bridgeport on this Mac.")

            SettingsField(label: "Public Base URL") {
                TextField("https://mcp.amesvt.com", text: $appState.publicBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await appState.save() } }
            }

            SettingsField(label: "Bind Host") {
                TextField("127.0.0.1", text: $appState.bindHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await appState.save() } }
            }

            HStack {
                Button {
                    Task { await appState.save() }
                } label: {
                    Label("Save Cloudflare Settings", systemImage: "checkmark.circle")
                }

                Button {
                    openCloudflareDocs()
                } label: {
                    Label("Open Tunnel Docs", systemImage: "safari")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tunnel target")
                    .font(.headline)
                Text("cloudflared should forward the chosen hostname to \(appState.localBaseURL). Expose individual connectors only after enabling their Public toggle.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cloudConnectorsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Cloud Connectors", subtitle: "Copy public Bridgeport endpoints into Claude, Anthropic API, Mistral Work, and Vibe Code.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Public connector requirements")
                    .font(.headline)
                Text("Claude and Mistral cloud connectors reach Bridgeport from their cloud infrastructure, so each connector needs a public base URL, Cloudflare routing, and the connector's Public toggle enabled.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    copy(appState.cloudConnectorExportJSON())
                } label: {
                    Label("Copy Cloud Export JSON", systemImage: "doc.on.doc")
                }
                .disabled(appState.publicCloudConnectors.isEmpty)

                Button {
                    copy(appState.allVibeCodeTOML())
                } label: {
                    Label("Copy Vibe TOML", systemImage: "terminal")
                }
                .disabled(appState.publicCloudConnectors.isEmpty)

                if !appState.allowQueryTokenAuth {
                    Button {
                        appState.allowQueryTokenAuth = true
                        Task { await appState.save() }
                    } label: {
                        Label("Enable Claude URL Fallback", systemImage: "link.badge.plus")
                    }
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

            Toggle("Use mounted 1Password Environment .env file", isOn: $appState.onePasswordEnvironment.enabled)
                .onChange(of: appState.onePasswordEnvironment.enabled) {
                    Task { await appState.save() }
                }

            SettingsField(label: "Environment Name") {
                TextField("Bridgeport", text: $appState.onePasswordEnvironment.environmentName)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsField(label: "Account ID") {
                TextField("1Password account UUID", text: $appState.onePasswordEnvironment.accountId)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsField(label: "Environment ID") {
                TextField("Environment UUID", text: $appState.onePasswordEnvironment.environmentId)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsField(label: "Local .env Path") {
                HStack {
                    TextField("~/.config/bridgeport/1password.env", text: $appState.onePasswordEnvironment.localEnvFilePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        selectOnePasswordEnvFile()
                    }
                }
            }

            HStack {
                Button {
                    Task { await appState.save() }
                } label: {
                    Label("Save 1Password Settings", systemImage: "checkmark.circle")
                }

                Button {
                    NSWorkspace.shared.open(URL(string: "onepassword://settings/labs")!)
                } label: {
                    Label("Open 1Password Labs", systemImage: "key")
                }
            }
        }
    }

    private var sourcesPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Sources", subtitle: "Import copies MCP definitions into Bridgeport. Mirror keeps reading the external source live.")

            HStack {
                Button {
                    importMCPs()
                } label: {
                    Label("Import MCPs", systemImage: "square.and.arrow.down")
                }

                Button {
                    mirrorMCPs()
                } label: {
                    Label("Mirror MCPs From...", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Primary Source")
                    .font(.headline)
                HStack {
                    TextField("Path to MCP plugin directory", text: $appState.connectorsPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        selectPrimarySource()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mirrored Sources")
                    .font(.headline)
                TextEditor(text: $appState.additionalConnectorPathsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                Button {
                    Task {
                        await appState.save()
                        await appState.reload()
                    }
                } label: {
                    Label("Apply Sources", systemImage: "checkmark.circle")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Imported Connectors")
                    .font(.headline)
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
        return panel
    }

    private func openCloudflareDocs() {
        if let url = URL(string: "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MetricView: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
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

private struct ConnectorRow: View {
    @Bindable var appState: AppState
    let connector: Connector

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(appState.activeSessions(for: connector) > 0 ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 9, height: 9)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.headline)
                    Text("\(connector.sourceKind.rawValue) • \(connector.configPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("Enabled", isOn: Binding(
                    get: { appState.connectorSettings(for: connector.name).enabled },
                    set: { _ in Task { await appState.toggleConnector(connector.name) } }
                ))
                .toggleStyle(.switch)
            }

            HStack(spacing: 16) {
                Toggle("Public", isOn: Binding(
                    get: { appState.connectorSettings(for: connector.name).exposePublicly },
                    set: { _ in Task { await appState.togglePublicExposure(connector.name) } }
                ))

                TextField("Public path", text: Binding(
                    get: { appState.connectorSettings(for: connector.name).publicPath ?? connector.name },
                    set: { newValue in
                        var settings = appState.connectorSettings(for: connector.name)
                        settings.publicPath = newValue
                        appState.connectorSettings[connector.name] = settings
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit {
                    Task {
                        await appState.setPublicPath(appState.connectorSettings(for: connector.name).publicPath ?? connector.name, for: connector.name)
                    }
                }

                Text("Sessions: \(appState.activeSessions(for: connector))")
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copy(appState.endpointURL(for: connector, publicEndpoint: false))
                } label: {
                    Label("Copy Local", systemImage: "link")
                }

                Button {
                    copy(appState.endpointURL(for: connector, publicEndpoint: true))
                } label: {
                    Label("Copy Public", systemImage: "globe")
                }
                .disabled(appState.publicBaseURL.isEmpty)
            }

            let requiredVars = connector.requiredEnvVarNames
            if !requiredVars.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Required Environment")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                            Label("Save Environment", systemImage: "checkmark.circle")
                        }
                    }
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

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
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
                    Text(appState.endpointURL(for: connector, publicEndpoint: true))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    if let url = appState.claudeCustomConnectorURL(for: connector) {
                        copy(url)
                    }
                } label: {
                    Label("Copy Claude URL", systemImage: "sparkles")
                }
                .disabled(appState.claudeCustomConnectorURL(for: connector) == nil)

                Button {
                    copy(appState.anthropicMessagesAPIJSON(for: connector))
                } label: {
                    Label("Copy Anthropic JSON", systemImage: "curlybraces")
                }

                Button {
                    copy(appState.mistralCustomConnectorJSON(for: connector))
                } label: {
                    Label("Copy Mistral Details", systemImage: "square.grid.2x2")
                }

                Button {
                    copy(appState.vibeCodeTOML(for: connector))
                } label: {
                    Label("Copy Vibe TOML", systemImage: "terminal")
                }
            }

            Text(appState.allowQueryTokenAuth ? "Claude app URL includes the Bridgeport token because Claude's app dialog does not provide a static header field. Mistral and Vibe should use Bearer auth instead." : "Claude app URL export is disabled until query-token fallback or OAuth support is enabled. Anthropic API, Mistral, and Vibe exports use Bearer auth.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
