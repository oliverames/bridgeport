import SwiftUI
import AppKit
import Sparkle

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

    // Sparkle only makes sense when running from an installed bundle whose
    // Info.plist carries the feed configuration; `swift run` and the CLI
    // paths have no SUFeedURL, so the updater stays nil there.
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        SettingsWindowCoordinator.shared.configure(appState: appState)

        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Label {
                Text("Bridgeport")
            } icon: {
                Image(nsImage: BridgeMenuBarIcon.image(running: appState.isDaemonRunning))
            }
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

            if let updaterController {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }

            Button("Quit Bridgeport") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(nsImage: BridgeMenuBarIcon.image(running: appState.isDaemonRunning))
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

    // SF Symbols has no bridge glyph, so the menu bar icon is a hand-drawn
    // suspension bridge rendered as a template image. When the daemon is
    // stopped the bridge draws at reduced alpha, which template rendering
    // shows as a dimmed icon.
    enum BridgeMenuBarIcon {
        static func image(running: Bool) -> NSImage {
            let side: CGFloat = 18
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
                let alpha: CGFloat = running ? 1.0 : 0.45
                let color = NSColor(calibratedWhite: 0, alpha: alpha)

                func stroke(_ path: NSBezierPath, width: CGFloat) {
                    color.setStroke()
                    path.lineWidth = width
                    path.lineCapStyle = .round
                    path.stroke()
                }

                func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                    NSPoint(x: x * side, y: y * side)
                }

                let deck = NSBezierPath()
                deck.move(to: pt(0.04, 0.34))
                deck.line(to: pt(0.96, 0.34))
                stroke(deck, width: 1.8)

                let cable = NSBezierPath()
                cable.move(to: pt(0.04, 0.36))
                cable.line(to: pt(0.24, 0.80))
                cable.curve(to: pt(0.76, 0.80), controlPoint1: pt(0.40, 0.42), controlPoint2: pt(0.60, 0.42))
                cable.line(to: pt(0.96, 0.36))
                stroke(cable, width: 1.4)

                for x in [0.24, 0.76] as [CGFloat] {
                    let tower = NSBezierPath()
                    tower.move(to: pt(x, 0.26))
                    tower.line(to: pt(x, 0.86))
                    stroke(tower, width: 1.8)
                }

                for x in [0.42, 0.50, 0.58] as [CGFloat] {
                    let t = (x - 0.50) / 0.26
                    let hangerTop = 0.50 + (0.80 - 0.50) * t * t
                    let hanger = NSBezierPath()
                    hanger.move(to: pt(x, hangerTop))
                    hanger.line(to: pt(x, 0.34))
                    stroke(hanger, width: 1.0)
                }

                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = running ? "Bridgeport running" : "Bridgeport stopped"
            return image
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
