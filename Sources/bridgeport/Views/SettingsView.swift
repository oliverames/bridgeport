import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var appState: AppState
    
    var body: some View {
        TabView {
            // General Tab
            Form {
                Section(header: Text("General Settings").font(.headline)) {
                    HStack {
                        Text("HTTP Port:")
                            .frame(width: 120, alignment: .trailing)
                        TextField("8080", text: $appState.port)
                            .frame(width: 80)
                            .onSubmit {
                                Task {
                                    await appState.save()
                                }
                            }
                        Text("(Requires daemon restart)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Connectors Path:")
                            .frame(width: 120, alignment: .trailing)
                        TextField("Path to MCP plugins", text: $appState.connectorsPath)
                            .disabled(true)
                        Button("Browse...") {
                            selectConnectorsPath()
                        }
                    }
                }
                
                Divider()
                    .padding(.vertical, 10)
                
                Section(header: Text("Daemon Management").font(.headline)) {
                    HStack {
                        Text("Status:")
                            .frame(width: 120, alignment: .trailing)
                        
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.isDaemonRunning ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            
                            Text(appState.isDaemonRunning ? "Running" : "Stopped")
                                .fontWeight(.medium)
                            
                            if appState.isDaemonInstalled && !appState.isDaemonRunning {
                                Text("(Installed as LaunchAgent)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if !appState.isDaemonInstalled {
                                Text("(Not Installed)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                    
                    HStack {
                        Spacer()
                            .frame(width: 128)
                        
                        if !appState.isDaemonInstalled {
                            Button(action: {
                                Task {
                                    await appState.installDaemon()
                                }
                            }) {
                                Label("Install Daemon", systemImage: "plus.circle")
                            }
                        } else {
                            Button(action: {
                                Task {
                                    await appState.uninstallDaemon()
                                }
                            }) {
                                Label("Uninstall Daemon", systemImage: "trash")
                            }
                            
                            Button(action: {
                                Task {
                                    await appState.restartDaemon()
                                }
                            }) {
                                Label("Restart Daemon", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .padding(30)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            
            // Security Tab
            Form {
                Section(header: Text("Security & API Token").font(.headline)) {
                    Text("The master API token is required for all web-hosted MCP client connections (e.g. Vibe, Claude Code) to authenticate with Bridgeport.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack(spacing: 8) {
                        Text("Master Token:")
                            .frame(width: 100, alignment: .trailing)
                        
                        HStack {
                            if appState.isShowingToken {
                                Text(appState.token)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(String(repeating: "•", count: 24))
                                    .font(.system(.body, design: .monospaced))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                        
                        Button(appState.isShowingToken ? "Hide" : "Show") {
                            appState.isShowingToken.toggle()
                        }
                        
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(appState.token, forType: .string)
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    
                    HStack {
                        Spacer()
                            .frame(width: 108)
                        
                        Button(action: {
                            Task {
                                await appState.rotateToken()
                            }
                        }) {
                            Label("Rotate Token...", systemImage: "key.horizontal")
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(30)
            .tabItem {
                Label("Security", systemImage: "lock.shield")
            }
            
            // Connectors Tab
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connectors")
                        .font(.headline)
                    Text("Enable/disable discovered connectors and configure their credentials.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Divider()
                    
                    if appState.discoveredConnectors.isEmpty {
                        Text("No Connectors Discovered")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(appState.discoveredConnectors, id: \.name) { connector in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    let isEnabled = !appState.disabledConnectors.contains(connector.name)
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(isEnabled ? Color.green : Color.gray.opacity(0.5))
                                            .frame(width: 8, height: 8)
                                        
                                        Toggle(connector.name, isOn: Binding(
                                            get: { isEnabled },
                                            set: { _ in
                                                Task {
                                                    await appState.toggleConnector(connector.name)
                                                }
                                            }
                                        ))
                                        .fontWeight(.semibold)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(connector.directoryPath)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                
                                // Show required environment variables
                                let requiredVars = connector.requiredEnvVarNames
                                if !requiredVars.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(requiredVars, id: \.self) { varName in
                                            HStack {
                                                Text(varName + ":")
                                                    .font(.system(.caption, design: .monospaced))
                                                    .frame(width: 220, alignment: .trailing)
                                                
                                                let binding = Binding<String>(
                                                    get: { appState.env[varName] ?? "" },
                                                    set: { newValue in
                                                        appState.env[varName] = newValue
                                                        Task {
                                                            await appState.save()
                                                        }
                                                    }
                                                )
                                                
                                                if isSensitiveKey(varName) {
                                                    SecureField("Enter \(varName)", text: binding)
                                                        .textFieldStyle(.roundedBorder)
                                                        .frame(maxWidth: .infinity)
                                                } else {
                                                    TextField("Enter \(varName)", text: binding)
                                                        .textFieldStyle(.roundedBorder)
                                                        .frame(maxWidth: .infinity)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.leading, 24)
                                }
                            }
                            .padding(.vertical, 4)
                            
                            Divider()
                        }
                    }
                }
                .padding(24)
            }
            .tabItem {
                Label("Connectors", systemImage: "cable.connector")
            }
        }
        .frame(width: 650, height: 520)
    }
    
    private func isSensitiveKey(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("token") || lower.contains("key") || lower.contains("secret") || lower.contains("password")
    }
    
    private func selectConnectorsPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Connectors Path"
        
        if panel.runModal() == .OK, let url = panel.url {
            appState.connectorsPath = url.path
            Task {
                await appState.save()
                await appState.reload()
            }
        }
    }
}
