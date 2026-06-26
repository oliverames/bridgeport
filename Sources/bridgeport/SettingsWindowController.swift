import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject {
    static let shared = SettingsWindowCoordinator()

    private var appState: AppState?
    private var windowController: SettingsWindowController?

    func configure(appState: AppState) {
        self.appState = appState
    }

    func installAppMenuItem() {
        guard NSApp.activationPolicy() == .regular else { return }
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

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettingsWindow()
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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
