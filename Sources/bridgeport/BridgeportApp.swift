import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, Sendable {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app (menu bar only, no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            SettingsWindowCoordinator.shared.installAppMenuItem()
            SettingsWindowCoordinator.shared.openSettingsIfRequested()
        }
    }
}

struct BridgeportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        SettingsWindowCoordinator.shared.configure(appState: appState)
    }

    var body: some Scene {
        MenuBarExtra("Bridgeport", systemImage: menuBarSymbol) {
            Label("Bridgeport", systemImage: menuBarSymbol)
                .font(.headline)

            let totalCount = appState.discoveredConnectors.count
            Text(menuSummary(totalCount: totalCount))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Cloudflare: \(appState.cloudflareStatusText)")
                .font(.caption)
                .foregroundStyle(appState.cloudflareStatus.state == .running ? .green : .secondary)

            Divider()

            Button("Open Settings") {
                openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button(appState.isReloading ? "Refreshing" : "Refresh") {
                Task {
                    await appState.reload()
                }
            }
            .disabled(appState.isReloading)

            Button(appState.isDaemonRunning ? "Restart Daemon" : "Start Daemon") {
                Task {
                    if appState.isDaemonRunning {
                        await appState.restartDaemon()
                    } else {
                        await appState.installDaemon()
                    }
                }
            }

            Button(appState.cloudflareStatus.state == .running ? "Restart Cloudflare" : "Start Cloudflare") {
                Task {
                    if appState.cloudflareStatus.state == .running {
                        await appState.restartCloudflareTunnel()
                    } else {
                        await appState.startCloudflareTunnel()
                    }
                }
            }
            .disabled(!appState.cloudflare.enabled)

            Divider()

            if appState.discoveredConnectors.isEmpty {
                Button("Configure Sources") {
                    openSettingsWindow()
                }
            } else {
                ForEach(appState.discoveredConnectors, id: \.name) { connector in
                    let activeCount = appState.activeSessions(for: connector)
                    Toggle(isOn: Binding(
                        get: { appState.connectorSettings(for: connector.name).enabled },
                        set: { _ in
                            Task {
                                await appState.toggleConnector(connector.name)
                            }
                        }
                    )) {
                        Text(connectorMenuTitle(connector.name, activeCount: activeCount))
                    }
                }
            }

            Divider()

            Button("Quit Bridgeport") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func openSettingsWindow() {
        SettingsWindowCoordinator.shared.openSettingsWindow()
    }

    private func menuSummary(totalCount: Int) -> String {
        let daemon = appState.isDaemonRunning ? "Running" : "Stopped"
        return "\(daemon) - \(appState.enabledConnectorCount)/\(totalCount) enabled - \(appState.activeSessionCount) active"
    }

    private func connectorMenuTitle(_ name: String, activeCount: Int) -> String {
        let suffix = activeCount > 0 ? " (\(activeCount))" : ""
        return shortMenuTitle(name, suffix: suffix)
    }

    private func shortMenuTitle(_ value: String, suffix: String = "") -> String {
        let maxLength = max(1, 30 - suffix.count)
        if value.count <= maxLength {
            return value + suffix
        }
        guard maxLength > 1 else {
            return String(value.prefix(maxLength)) + suffix
        }
        return String(value.prefix(maxLength - 1)) + "…" + suffix
    }

    private var menuBarSymbol: String {
        let preferred = appState.isDaemonRunning
            ? "app.connected.to.app.below.fill"
            : "app.connected.to.app.below"
        let fallback = appState.isDaemonRunning
            ? "bolt.fill"
            : "bolt"

        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil ? fallback : preferred
    }
}
