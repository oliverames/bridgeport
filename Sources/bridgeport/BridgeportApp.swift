import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, Sendable {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app (menu bar only, no Dock icon)
        NSWindow.allowsAutomaticWindowTabbing = false
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
            Label {
                Text(menuSummary(totalCount: totalCount))
            } icon: {
                Image(systemName: appState.isDaemonRunning ? "checkmark.circle.fill" : "stop.circle")
                    .foregroundStyle(appState.isDaemonRunning ? .green : .secondary)
            }

            Label {
                Text("Cloudflare: \(appState.cloudflareStatusText)")
            } icon: {
                Image(systemName: cloudflareStatusIcon)
                    .foregroundStyle(cloudflareStatusTint)
            }

            Divider()

            Button("Settings…") {
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

            CommandGroup(replacing: .help) {
                Button("Bridgeport Help") {
                    openDocumentation()
                }

                Button("Report Bridgeport Issue") {
                    openIssueReporter()
                }
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

    private var menuBarSymbol: String {
        let preferred = appState.isDaemonRunning
            ? "app.connected.to.app.below.fill"
            : "app.connected.to.app.below"
        let fallback = appState.isDaemonRunning
            ? "bolt.fill"
            : "bolt"

        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil ? fallback : preferred
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

    private func openDocumentation() {
        if let url = URL(string: "https://github.com/oliverames/bridgeport#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openIssueReporter() {
        if let url = URL(string: "https://github.com/oliverames/bridgeport/issues") {
            NSWorkspace.shared.open(url)
        }
    }
}
