import AppKit
import SwiftUI
import GrammyCore

@main
enum GrammyMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let account = ChatGPTAccount()
    private let gemini = GeminiAccount()
    private lazy var model = RewriteModel(account: account, gemini: gemini)
    private var preview: NSWindow?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private let shortcut = GlobalShortcut()
    private var serviceActive = false
    private var serviceResult: String?
    private var serviceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenus()
        NSApp.servicesProvider = self
        shortcut.action = { [weak self] in self?.improveSelection() }
        if !shortcut.register() { account.message = "The global shortcut is already in use. Use Services, or paste a message into Grammy." }
        model.cancelAction = { [weak self] in self?.dismissPreview() }
        if CommandLine.arguments.contains("--sample") { showSample() }
        else { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop(); account.cancelSignIn() }

    @objc(improveSlackMessage:userData:error:)
    func improveSlackMessage(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard !serviceActive, !model.isBusy, !model.isReplacing, preview?.isVisible != true else {
            error.pointee = "Finish or cancel the current Grammy preview first."; return
        }
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Select some text to improve."; return
        }
        serviceActive = true; serviceResult = nil
        model.prepare(text, source: "Selected text") { [weak self] replacement in
            self?.serviceResult = replacement
            self?.dismissPreview()
        }
        showPreview()
        // Native Services holds the source selection for this modal transaction. End before NSTimeout.
        let timer = Timer(timeInterval: 240, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.model.cancel() }
        }
        serviceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        model.generate()
        NSApp.runModal(for: preview!)
        timer.invalidate(); serviceTimer = nil
        model.stop()
        serviceActive = false
        pasteboard.clearContents()
        if let serviceResult { pasteboard.setString(serviceResult, forType: .string) }
        self.serviceResult = nil
        model.replaceAction = nil; model.hasTarget = false
    }

    private func showPreview() {
        if preview == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 530),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Grammy"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RewriteView(model: model, settings: { [weak self] in self?.showSettings() }))
            window.delegate = self
            window.center()
            preview = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preview?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if serviceActive {
            // End the service transaction before opening another window, keeping the draft unchanged.
            dismissPreview()
        }
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Grammy Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(account: account, gemini: gemini,
                sample: { [weak self] in self?.showSample() }, stopRewriting: { [weak self] in self?.model.stop() }))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func newMessage() {
        guard !serviceActive else { return }
        model.prepare("", source: "Your message")
        showPreview()
    }
    @objc private func showSample() {
        guard !serviceActive else { return }
        model.sample(); showPreview()
    }
    private func improveSelection() {
        guard !serviceActive && !model.isBusy && !model.isReplacing else { NSSound.beep(); return }
        do {
            let target = try TextTarget.capture()
            model.prepare(target.original, source: target.app.localizedName ?? "Selected text") { [weak self] replacement in
                try await target.replace(with: replacement)
                self?.dismissPreview()
            }
            showPreview(); model.generate()
        } catch {
            model.prepare("", source: "Your message")
            model.error = error.localizedDescription
            showPreview()
        }
    }
    private func dismissPreview() {
        model.stop()
        if serviceActive { NSApp.stopModal() }
        preview?.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === preview { model.cancel(); return false }
        return true
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func setUpMenus() {
        let menu = NSMenu()
        menu.addItem(item("New message…", #selector(newMessage), "n"))
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(item("Sample preview", #selector(showSample), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Grammy", #selector(quit), "q"))
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Grammy")
        statusItem.menu = menu
        self.statusItem = statusItem

        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Grammy")
        appMenu.addItem(item("Settings…", #selector(showSettings), ","))
        let services = NSMenu(title: "Services")
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        appMenu.addItem(serviceItem)
        NSApp.servicesMenu = services
        appMenu.addItem(item("Quit Grammy", #selector(quit), "q"))
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: name, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = edit; mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
    private func item(_ title: String, _ action: Selector, _ shortcut: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.target = self; return item
    }
}
