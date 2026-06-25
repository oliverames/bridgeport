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
        MenuBarExtra("Bridgeport", systemImage: "app.connected.to.app.below.fill") {
            Text("Bridgeport Gateway")
                .font(.headline)
            
            Divider()
            
            if appState.discoveredConnectors.isEmpty {
                Text("No Connectors Discovered")
                    .foregroundColor(.secondary)
            } else {
                Text("Connectors:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
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
            
            HStack {
                Text("Daemon Status:")
                Text(appState.isDaemonRunning ? "Running" : "Stopped")
                    .foregroundColor(appState.isDaemonRunning ? .green : .red)
            }
            
            Button("Settings...") {
                // Open standard SwiftUI Settings panel
                openSettings()
                // Force window activation to bring settings to the front
                NSApp.activate(ignoringOtherApps: true)
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
}
