import AppKit
import ServiceManagement

// CLI helper: `DockHack --send relocate|selftest|enable|disable|status` pokes the running app.
let commandPrefix = "dev.local.dockhack."
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--send" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(commandPrefix + args[2]), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dock = DockController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("DockHack launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        dock.onStateChange = { [weak self] in self?.updateIcon() }
        dock.start()
        updateIcon()

        for cmd in ["relocate", "selftest", "enable", "disable", "status"] {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(handleCommand(_:)), name: Notification.Name(commandPrefix + cmd),
                object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func handleCommand(_ note: Notification) {
        let cmd = note.name.rawValue.replacingOccurrences(of: commandPrefix, with: "")
        Log.write("command: \(cmd)")
        switch cmd {
        case "relocate": dock.relocate(reason: "command")
        case "selftest": dock.selfTestBump()
        case "enable": dock.enabled = true
        case "disable": dock.enabled = false
        default:
            Log.write("status: tap=\(dock.tapActive) ax=\(dock.hasAccessibility) enabled=\(dock.enabled) anchor=\(dock.anchor?.name ?? "-") dock=\(Displays.dockDisplay(among: dock.displays)?.name ?? "-")")
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let ok = dock.tapActive && dock.enabled
        let name = ok ? "dock.rectangle" : "exclamationmark.triangle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "DockHack")
            ?? NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: "DockHack")
        button.appearsDisabled = !dock.enabled
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        dock.refreshDisplays(reason: "menu")

        let current = Displays.dockDisplay(among: dock.displays)
        menu.addItem(info("Dock is on: \(current?.name ?? "unknown")"))
        menu.addItem(info("Anchored to: \(dock.anchor?.name ?? "—")"))
        if !dock.statusNote.isEmpty { menu.addItem(info("⚠️ \(dock.statusNote)")) }
        if Displays.dockOrientation() != "bottom" { menu.addItem(info("⚠️ Dock position isn't “Bottom” – nothing to do")) }

        if !dock.tapActive {
            menu.addItem(.separator())
            menu.addItem(info("⚠️ Needs Accessibility permission"))
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }

        menu.addItem(.separator())
        let toggle = item("Keep Dock on anchor display", #selector(toggleEnabled))
        toggle.state = dock.enabled ? .on : .off
        menu.addItem(toggle)
        let move = item("Move Dock there now", #selector(moveNow))
        move.isEnabled = dock.tapActive
        menu.addItem(move)

        menu.addItem(.separator())
        menu.addItem(info("Anchor display"))
        let auto = item("Topmost display (automatic)", #selector(chooseAnchor(_:)))
        auto.representedObject = nil
        auto.state = dock.anchorPreferenceUUID == nil ? .on : .off
        auto.indentationLevel = 1
        menu.addItem(auto)
        for d in dock.displays {
            let it = item(d.name, #selector(chooseAnchor(_:)))
            it.representedObject = d.uuid
            it.state = dock.anchorPreferenceUUID == d.uuid ? .on : .off
            it.indentationLevel = 1
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let login = item("Launch at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show log", #selector(showLog)))
        menu.addItem(item("Quit DockHack", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func toggleEnabled() { dock.enabled.toggle(); updateIcon() }
    @objc private func moveNow() { dock.relocate(reason: "menu") }
    @objc private func chooseAnchor(_ sender: NSMenuItem) { dock.anchorPreferenceUUID = sender.representedObject as? String }
    @objc private func openAccessibility() {
        dock.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.write("login item error: \(error)")
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
    @objc private func showLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
