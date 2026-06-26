import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, Sendable {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app (menu bar only, no Dock icon)
        NSApp.setActivationPolicy(.accessory)
    }
}

struct BridgeportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra("Bridgeport", systemImage: appState.isDaemonRunning ? "app.connected.to.app.below.fill" : "app.connected.to.app.below") {
            Text("Bridgeport")
                .font(.headline)

            let totalCount = appState.discoveredConnectors.count
            Text("\(appState.enabledConnectorCount)/\(totalCount) enabled, \(appState.activeSessionCount) active")
                .font(.caption)

            Divider()

            if appState.discoveredConnectors.isEmpty {
                Button("No Connectors Discovered (Configure Path...)") {
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
                        Text(activeCount > 0 ? "\(connector.name) (\(activeCount))" : connector.name)
                    }
                }
            }

            Divider()

            Button("Refresh Status") {
                Task {
                    appState.checkDaemonStatus()
                    await appState.refreshDaemonRuntimeStatus()
                }
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
                let status = appState.isDaemonRunning ? "● Running" : "○ Stopped"
                let action = appState.isDaemonRunning ? "Click to Restart" : "Click to Start"
                Text("Daemon: \(status), \(action)")
            }

            Button("Settings...") {
                openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Bridgeport") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView(appState: appState)
        }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}
