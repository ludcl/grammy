import AppKit
import ApplicationServices
import Carbon
import GrammyCore

@MainActor
struct TextTarget {
    let app: NSRunningApplication
    let element: AXUIElement
    let original: String
    let fullValue: String
    let selection: CFRange

    static func capture() throws -> TextTarget {
        guard AXIsProcessTrusted() else { throw GrammyError("Enable Grammy in System Settings → Privacy & Security → Accessibility to use the shortcut. Services can work without it.") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw GrammyError("Select text in Slack, then press Control–Option–Command–G.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw GrammyError("This app does not expose its selected text. Try its Services menu instead.")
        }
        let element = focused as! AXUIElement
        let role = attribute(element, kAXRoleAttribute) as? String
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              role == kAXTextAreaRole || role == kAXTextFieldRole,
              let full = attribute(element, kAXValueAttribute) as? String,
              let selected = attribute(element, kAXSelectedTextAttribute) as? String,
              !selected.isEmpty, let range = selectedRange(element), range.length > 0,
              range.location >= 0, range.location + range.length <= (full as NSString).length,
              (full as NSString).substring(with: NSRange(location: range.location, length: range.length)) == selected else {
            throw GrammyError("Select editable text first. If this editor does not expose the selection, use Services → Improve Slack message, or paste into Grammy.")
        }
        return TextTarget(app: app, element: element, original: selected, fullValue: full, selection: range)
    }

    func replace(with text: String) async throws {
        guard !app.isTerminated else { throw GrammyError("The source app was closed. Copy the suggestion instead.") }
        guard app.activate(options: []) else { throw GrammyError("Could not return to the source app. Copy the suggestion instead.") }
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = Self.attribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, element),
              Self.attribute(element, kAXValueAttribute) as? String == fullValue,
              Self.attribute(element, kAXSelectedTextAttribute) as? String == original,
              let currentRange = Self.selectedRange(element),
              currentRange.location == selection.location, currentRange.length == selection.length else {
            throw GrammyError("The draft, selection, or focused editor changed. Nothing was replaced. Select the text again, or copy this suggestion.")
        }
        var writable: DarwinBoolean = false
        let available = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable)
        if available == .success && writable.boolValue {
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                throw GrammyError("The editor refused replacement. Copy the suggestion instead.")
            }
            return
        }
        // Some Electron editors expose selection for reading but require normal paste for writing.
        // Recheck the target immediately before injecting Cmd-V; never send Return.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw GrammyError("The focused app changed. Copy the suggestion instead.")
        }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw GrammyError("Could not paste into the source editor.")
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChange = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Restore only if another app/user has not changed the clipboard since our paste.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register() -> Bool {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in shortcut.action?() }
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: 0x47524D59, id: 1)
        return RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey | cmdKey), id,
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
