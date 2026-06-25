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
            // Title section
            Text("Bridgeport")
                .font(.headline)
            
            let enabledCount = appState.discoveredConnectors.filter { !appState.disabledConnectors.contains($0.name) }.count
            let totalCount = appState.discoveredConnectors.count
            Text("\(enabledCount)/\(totalCount) connectors active")
                .font(.caption)
            
            Divider()
            
            if appState.discoveredConnectors.isEmpty {
                Button("No Connectors Discovered (Configure Path...)") {
                    openSettingsWindow()
                }
            } else {
                ForEach(appState.discoveredConnectors, id: \.name) { connector in
                    Toggle(connector.name, isOn: Binding(
                        get: { !appState.disabledConnectors.contains(connector.name) },
                        set: { _ in
                            Task {
                                await appState.toggleConnector(connector.name)
                            }
                        }
                    ))
                }
            }
            
            Divider()
            
            // Daemon status as a button
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
                Text("Daemon: \(status) — \(action)")
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
