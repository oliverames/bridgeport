import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject {
    static let shared = SettingsWindowCoordinator()

    private var appState: AppState?
    private var windowController: SettingsWindowController?
    private var didHandleOpenSettingsLaunchRequest = false

    func configure(appState: AppState) {
        self.appState = appState
        guard Self.launchRequestedSettingsWindow() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.openSettingsIfRequested()
        }
    }

    func installAppMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }

        for item in appMenu.items where item.title == "Settings..." || item.title == "Settings…" {
            appMenu.removeItem(item)
        }

        guard !appMenu.items.contains(where: { $0.action == #selector(openSettingsFromMenu(_:)) }) else {
            return
        }

        let item = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        appMenu.insertItem(item, at: min(2, appMenu.items.count))
    }

    func openSettingsWindow() {
        guard let appState else {
            logMessage("SettingsWindowCoordinator: AppState not configured")
            return
        }

        NSApp.setActivationPolicy(.regular)
        if windowController == nil {
            windowController = SettingsWindowController(appState: appState)
        }
        windowController?.show()
        installAppMenuItem()
    }

    func openSettingsIfRequested() {
        guard !didHandleOpenSettingsLaunchRequest else { return }
        guard Self.launchRequestedSettingsWindow() else { return }
        guard appState != nil else { return }
        didHandleOpenSettingsLaunchRequest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openSettingsWindow()
        }
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettingsWindow()
    }

    private static func launchRequestedSettingsWindow(arguments: [String] = CommandLine.arguments) -> Bool {
        if ProcessInfo.processInfo.environment["BRIDGEPORT_OPEN_SETTINGS"] == "1" {
            return true
        }

        return arguments.dropFirst().contains { argument in
            argument == "--open-settings" || argument.hasPrefix("--open-settings=")
        }
    }
}

@MainActor
private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(appState: AppState) {
        let initialSize = NSSize(width: 980, height: 680)
        let hostingController = NSHostingController(rootView: SettingsView(appState: appState))
        hostingController.view.frame = NSRect(origin: .zero, size: initialSize)

        if #available(macOS 14.0, *) {
            hostingController.sceneBridgingOptions = .all
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Bridgeport Settings"
        window.identifier = NSUserInterfaceItemIdentifier("BridgeportSettingsWindow")
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = nil
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
