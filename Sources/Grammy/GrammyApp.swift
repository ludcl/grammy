import AppKit
import ApplicationServices
import SwiftUI
import OSLog
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
    typealias CapturedService = (text: FormattedText, source: String, replace: (FormattedText) async throws -> Void)
    typealias ServiceCapture = (FormattedText) async throws -> CapturedService
    private lazy var account = ChatGPTAccount()
    private lazy var gemini = GeminiAccount()
    private lazy var model = suppliedModel ?? RewriteModel(account: account, gemini: gemini)
    private let suppliedModel: RewriteModel?
    private let suppliedServiceCapture: ServiceCapture?
    private var preview: NSWindow?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private let shortcut = GlobalShortcut()
    private var serviceActive = false
    private var sourceApplication: NSRunningApplication?
    private let captureLog = Logger(subsystem: "local.grammy.app", category: "capture")

    init(model: RewriteModel? = nil, serviceCapture: ServiceCapture? = nil) {
        suppliedModel = model
        suppliedServiceCapture = serviceCapture
        super.init()
        self.model.cancelAction = { [weak self] in self?.dismissPreview() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier { sourceApplication = app }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        setUpMenus()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        shortcut.action = { [weak self] in self?.improveSelection() }
        if !shortcut.register() { account.message = "The global shortcut is already in use. Use Services, or paste a message into Grammy." }
        if CommandLine.arguments.contains("--sample") { showSample() }
        else { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop(); account.cancelSignIn() }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        sourceApplication = app
    }

    @objc(improveMessage:userData:error:)
    func improveMessage(_ pasteboard: NSPasteboard, userData: String?, error serviceError: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // This is an input-only Service. Native return types would let Electron
        // replace the selection before the async preview or Copy has completed.
        // Leave the input board untouched, including on rejected requests.
        captureLog.notice("Services request received")
        let text = FormattedText.read(pasteboard)
        guard !serviceActive, !model.isBusy, !model.isReplacing, preview?.isVisible != true else {
            serviceError.pointee = "Finish or cancel the current Grammy preview first."; return
        }
        guard let text, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            serviceError.pointee = "Select some text to improve."; return
        }
        serviceActive = true
        // Return before copying: Electron can block Copy while waiting for a
        // Services reply. Remember the source because Grammy may already be active.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? sourceApplication : frontmost
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.serviceActive = false }
            do {
                let captured: CapturedService
                if let capture = self.suppliedServiceCapture {
                    captured = try await capture(text)
                } else {
                    guard AXIsProcessTrusted() else {
                        throw GrammyError("Enable Grammy's Accessibility permission to capture emojis and replace the selected text.")
                    }
                    let target = try TextTarget.captureServiceInput(text, preferred: source)
                    let formatted = try await target.copySelection()
                    captured = (formatted, target.app.localizedName ?? "Selected text", { try await target.replace(with: $0) })
                }
                self.captureLog.notice("Formatted selection captured")
                self.model.prepare(captured.text, source: captured.source) { [weak self] replacement in
                    try await captured.replace(replacement)
                    self?.dismissPreview()
                }
                self.showPreview()
                self.model.generate()
            } catch {
                self.captureLog.notice("Services capture failed")
                self.model.prepare(text, source: "Selected text")
                self.showPreview()
                // Preserve the capture failure instead of masking it with a
                // generic missing-emoji error from the lossy Services input.
                if (try? Rewrite.validateInput(text.modelText)) != nil {
                    self.model.generate()
                    self.model.error = error.localizedDescription + " You can still copy a complete suggestion."
                } else {
                    self.model.error = error.localizedDescription + " The editor's Services text is incomplete. Select the message again."
                }
            }
        }
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
            improveCopiedSelection(target)
        } catch {
            model.prepare("", source: "Your message")
            model.error = error.localizedDescription
            showPreview()
        }
    }
    private func improveCopiedSelection(_ target: TextTarget) {
        serviceActive = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.serviceActive = false }
            do {
                try await self.prepareSelection(target)
            } catch {
                self.model.prepare("", source: "Your message")
                self.model.error = error.localizedDescription
                self.showPreview()
            }
        }
    }
    private func prepareSelection(_ target: TextTarget) async throws {
        let text = try await target.copySelection()
        model.prepare(text, source: target.app.localizedName ?? "Selected text") { [weak self] replacement in
            try await target.replace(with: replacement)
            self?.dismissPreview()
        }
        showPreview()
        model.generate()
    }
    private func dismissPreview() {
        model.stop()
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
