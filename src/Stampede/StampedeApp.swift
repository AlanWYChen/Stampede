import AppKit
import Combine
import SwiftUI

@main struct StampedeApplication {
    @MainActor static func main() {
        if ProcessInfo.processInfo.arguments.contains("--keychain-self-test") {
            let success = ClipboardSelfTest.keychainRoundTrip()
            print(
                success ? "PASS: disposable local Keychain key creation and reload" : "FAIL: local Keychain integration"
            )
            exit(success ? 0 : 1)
        }
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            let success = ClipboardSelfTest.run()
            print(
                success
                    ? "PASS: native text/PNG/TIFF/JPEG/HEIC clipboard round trips, alpha, exclusions, activation, and clear (private pasteboard)"
                    : "FAIL: native clipboard integration"
            )
            exit(success ? 0 : 1)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var settingsWindow: NSWindow?
    private var terminating = false
    private var showingRecovery = false
    private var observer: AnyCancellable?
    private let preview = ProcessInfo.processInfo.arguments.contains("--preview")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let identifier = Bundle.main.bundleIdentifier,
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            })
        {
            NSApp.terminate(nil)
            return
        }
        model = AppModel(preview: preview)
        model.onRecoveryNeeded = { [weak self] error in self?.showHistoryRecovery(error) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StampIcon.menuBarImage()
        statusItem.button?.setAccessibilityLabel("Stampede clipboard history")
        statusItem.button?.toolTip = "Stampede — Clipboard History"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
        observer = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.button?.toolTip =
                    self.model.paused ? "Stampede — Capture paused" : "Stampede — Clipboard History"
            }
        }
        if !model.setupComplete { showWelcome() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.poll()
        model.refreshLoginStatus()
        rebuild(menu)
    }

    @discardableResult private func add(
        _ title: String,
        to menu: NSMenu,
        action: Selector? = nil,
        represented: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        add("Stampede · \(model.history.entries.count) / \(model.history.capacity)", to: menu)
        if !model.setupComplete {
            add("Enable Clipboard History…", to: menu, action: #selector(welcome))
        } else {
            if model.paused { add("Capture paused", to: menu) }
            if model.history.entries.isEmpty {
                add(
                    model.ready ? "Copy text or an image to start your history" : "Saved history is not loaded",
                    to: menu
                )
            }
            for entry in model.history.entries {
                let item = add(entry.preview, to: menu, action: #selector(selectEntry(_:)), represented: entry.id)
                item.state = entry.id == model.currentID ? .on : .off
                item.toolTip = "Make this copy the active clipboard, then paste as usual."
                if let image = entry.image {
                    #if compiler(>=6.4)
                        // SDK 27 builds hide menu images by default; these previews are content.
                        if #available(macOS 27.0, *) {
                            item.preferredImageVisibility = .visible
                        }
                    #endif
                    if let thumbnail = image.thumbnail.flatMap(NSImage.init(data:)) {
                        let scale = 32 / max(thumbnail.size.width, thumbnail.size.height)
                        thumbnail.size = NSSize(
                            width: thumbnail.size.width * scale,
                            height: thumbnail.size.height * scale
                        )
                        item.image = thumbnail
                    } else {
                        item.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Saved image")
                    }
                    if image.data == nil {
                        item.isEnabled = false
                        item.title += " · Unavailable"
                        item.toolTip =
                            "This saved image is missing or unreadable. Clear history to remove unavailable entries."
                    }
                    item.setAccessibilityLabel(item.title)
                }
            }
            menu.addItem(.separator())
            add(model.storageStatus, to: menu)
            if let error = model.operationError { add(error, to: menu) }
            if !model.ready || model.storageStatus.contains("not saved") {
                add("Retry History Storage", to: menu, action: #selector(retry))
            }
            if model.accessRequired {
                add("Clipboard Access Needed…", to: menu, action: #selector(checkAccess))
            }
            if model.ready {
                add(model.paused ? "Resume Capture" : "Pause Capture", to: menu, action: #selector(togglePause))
                let limit = add("History Limit", to: menu)
                let submenu = NSMenu()
                for capacity in [10, 20] {
                    let item = add(
                        "\(capacity) items",
                        to: submenu,
                        action: #selector(setCapacity(_:)),
                        represented: capacity
                    )
                    item.state = capacity == model.history.capacity ? .on : .off
                }
                limit.submenu = submenu
                limit.isEnabled = true
                add("Clear Clipboard…", to: menu, action: #selector(clearClipboard))
            }
        }
        menu.addItem(.separator())
        add("Settings…", to: menu, action: #selector(showSettings))
        let quit = add("Quit Stampede", to: menu, action: #selector(quit))
        quit.keyEquivalent = "q"
    }

    @objc private func selectEntry(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { model.activate(id) }
    }

    @objc private func setCapacity(_ sender: NSMenuItem) {
        if let capacity = sender.representedObject as? Int { model.setCapacity(capacity) }
    }

    @objc private func togglePause() { model.togglePause() }

    @objc private func retry() { model.retry() }

    @objc private func checkAccess() {
        model.requestAccess()
        showSettings()
    }

    @objc private func welcome() { showWelcome() }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to Stampede"
        alert.informativeText =
            "Keep your latest 10 or 20 text and image copies, encrypted on this Mac, even after a restart. Select an older copy from the menu bar, then paste normally on Mac or iPad through Universal Clipboard.\n\nEnabling history also enables launch at login. Unmarked passwords can be captured; you can pause or clear history at any time. macOS may require clipboard access approval."
        alert.addButton(withTitle: "Enable History & Launch at Login")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { model.completeSetup() }
    }

    private func showHistoryRecovery(_ detail: String) {
        guard !showingRecovery, !terminating else { return }
        showingRecovery = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stampede couldn’t open your clipboard history"
        alert.informativeText =
            "Your saved history may be missing or damaged, or its encryption key may be unavailable. Would you like to try again?\n\nReset starts a new, empty history and permanently discards your saved items. Your current Mac clipboard will stay unchanged.\n\nDetails: \(detail)"
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        let response = alert.runModal()
        showingRecovery = false
        if response == .alertFirstButtonReturn {
            model.retry()
        } else if response == .alertSecondButtonReturn {
            model.resetHistory()
            rebuildMenu()
        }
    }

    @objc private func clearClipboard() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear your clipboard?"
        alert.informativeText =
            "This clears the current Mac clipboard and permanently removes all clipboard history saved by Stampede. It does not erase items already pasted or stored on your other devices."
        alert.addButton(withTitle: "Clear Clipboard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.clearClipboard()
            rebuildMenu()
        }
    }

    /// Drop cleared titles and thumbnails now rather than when the menu next opens.
    private func rebuildMenu() { if let menu = statusItem?.menu { rebuild(menu) } }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Stampede Settings"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        model.refreshLoginStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil, !terminating else { return .terminateNow }
        terminating = true
        Task {
            let saved = await model.prepareToQuit()
            if saved {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "Some history changes could not be saved"
                alert.informativeText =
                    "Stay open to retry saving, or quit and lose changes made since the last successful save."
                alert.addButton(withTitle: "Stay Open")
                alert.addButton(withTitle: "Quit Anyway")
                NSApp.activate(ignoringOtherApps: true)
                let quit = alert.runModal() == .alertSecondButtonReturn
                terminating = false
                sender.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }
}
