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

    static func capture(in source: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
                        matching serviceInput: FormattedText? = nil) throws -> TextTarget {
        guard AXIsProcessTrusted() else { throw GrammyError("Enable Grammy in System Settings → Privacy & Security → Accessibility to use the shortcut. Services can work without it.") }
        guard let app = source,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw GrammyError("Select text in an editor, then press Control–Option–Command–G.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Electron's Services menu can leave AX focus on the conversation list.
        // Recover only a unique selected editor whose wording matches the input.
        if let serviceInput {
            if let focused = attribute(application, kAXFocusedUIElementAttribute),
               CFGetTypeID(focused) == AXUIElementGetTypeID(),
               let target = selectedEditor(focused as! AXUIElement, in: app),
               target.matchesServiceInput(serviceInput) { return target }
            var pending = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [application]
            var matches: [TextTarget] = [], visited = 0
            while let candidate = pending.popLast(), visited < 1500 {
                visited += 1
                if let target = selectedEditor(candidate, in: app), target.matchesServiceInput(serviceInput) {
                    matches.append(target)
                }
                if let children = attribute(candidate, kAXChildrenAttribute) as? [AXUIElement] {
                    pending.append(contentsOf: children)
                }
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw GrammyError("More than one editor has this selection. Select your message again.") }
            throw GrammyError("This app has no editor matching the Services selection.")
        }
        guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw GrammyError("This app does not expose its selected text. Try its Services menu instead.")
        }
        let element = focused as! AXUIElement
        let role = attribute(element, kAXRoleAttribute) as? String
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              role == kAXTextAreaRole || role == kAXTextFieldRole else {
            throw GrammyError("The focused control is not an editable text field. Select your message again.")
        }
        guard let full = attribute(element, kAXValueAttribute) as? String else {
            throw GrammyError("The editor does not expose its draft text.")
        }
        guard let selected = attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty else {
            throw GrammyError("The editor does not expose selected text. Select your message again.")
        }
        guard let range = selectedRange(element), range.length > 0, range.location >= 0 else {
            throw GrammyError("The editor does not expose the selection range.")
        }
        return TextTarget(app: app, element: element, original: selected, fullValue: full, selection: range)
    }

    static func captureServiceInput(_ text: FormattedText, preferred source: NSRunningApplication?) throws -> TextTarget {
        if let source, let target = try? capture(in: source, matching: text) { return target }
        // Services can arrive while the source app is already in the background.
        // The callback does not identify its sender. Recover a unique selection,
        // never an arbitrary foreground editor or an unselected draft.
        let matches = NSWorkspace.shared.runningApplications.compactMap { app -> TextTarget? in
            guard app.activationPolicy == .regular, app.isFinishedLaunching,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.processIdentifier != source?.processIdentifier else { return nil }
            return try? capture(in: app, matching: text)
        }
        guard matches.count == 1 else {
            throw GrammyError("Could not identify a unique source editor. Bring your editor forward and select the message again.")
        }
        return matches[0]
    }

    private static func selectedEditor(_ element: AXUIElement, in app: NSRunningApplication) -> TextTarget? {
        let role = attribute(element, kAXRoleAttribute) as? String
        guard role == kAXTextAreaRole || role == kAXTextFieldRole,
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let full = attribute(element, kAXValueAttribute) as? String,
              let selected = attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty,
              let range = selectedRange(element), range.location >= 0, range.length > 0 else { return nil }
        return TextTarget(app: app, element: element, original: selected, fullValue: full, selection: range)
    }

    func matchesServiceInput(_ text: FormattedText) -> Bool {
        func normalized(_ value: String) -> String {
            var value = value
            for emoji in Rewrite.emojis(in: value) { value = value.replacingOccurrences(of: emoji, with: "") }
            for shortcode in Rewrite.shortcodes(in: value) { value = value.replacingOccurrences(of: shortcode, with: "") }
            return value.replacingOccurrences(of: "\u{fffc}", with: "")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return normalized(original) == normalized(text.string)
    }

    func copySelection() async throws -> FormattedText {
        NSApp.yieldActivation(to: app)
        guard app.activate(options: []) else { throw GrammyError("Could not return to the source editor.") }
        try await Task.sleep(for: .milliseconds(180))
        restoreEditorFocus()
        try await Task.sleep(for: .milliseconds(100))
        let focused = Self.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
        guard let focused, CFEqual(focused, element),
              Self.attribute(element, kAXValueAttribute) as? String == fullValue,
              Self.attribute(element, kAXSelectedTextAttribute) as? String == original,
              let range = Self.selectedRange(element), range.location == selection.location, range.length == selection.length else {
            throw GrammyError("The draft or selection changed before capture. Nothing was changed. Select the message again.")
        }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = board.changeCount
        try performEditCommand("c", keyCode: kVK_ANSI_C)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if board.changeCount != before { break }
        }
        guard board.changeCount != before else { throw GrammyError("The editor did not copy its selection. Nothing was changed.") }
        let copiedCount = board.changeCount
        defer {
            if board.changeCount == copiedCount {
                board.clearContents()
                let items = saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        // Electron AX text omits inline emoji images or represents them as U+FFFC.
        // The clipboard supplies the real selected text and formatting. Recheck the AX
        // snapshot to establish that it still belongs to the captured selection.
        guard Self.attribute(element, kAXValueAttribute) as? String == fullValue,
              Self.attribute(element, kAXSelectedTextAttribute) as? String == original,
              let range = Self.selectedRange(element), range.location == selection.location, range.length == selection.length,
              let text = FormattedText.read(board), matchesServiceInput(text),
              !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GrammyError("The selection changed while copying. Nothing was changed.")
        }
        return text
    }

    func replace(with text: FormattedText) async throws {
        guard !app.isTerminated else { throw GrammyError("The source app was closed. Copy the suggestion instead.") }
        NSApp.yieldActivation(to: app)
        guard app.activate(options: []) else { throw GrammyError("Could not return to the source app. Copy the suggestion instead.") }
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        restoreEditorFocus()
        try await Task.sleep(for: .milliseconds(100))
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = Self.attribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, element),
              Self.attribute(element, kAXValueAttribute) as? String == fullValue,
              Self.attribute(element, kAXSelectedTextAttribute) as? String == original,
              let currentRange = Self.selectedRange(element),
              currentRange.location == selection.location, currentRange.length == selection.length else {
            throw GrammyError("The draft, selection, or focused editor changed. Nothing was replaced. Select the text again, or copy this suggestion.")
        }
        var writable: DarwinBoolean = false
        let available = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable)
        if text.codeRanges.isEmpty && text.attributed.length > 0 && text.attributed.attributes(at: 0, effectiveRange: nil).isEmpty && available == .success && writable.boolValue {
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text.string as CFString) == .success else {
                throw GrammyError("The editor refused replacement. Copy the suggestion instead.")
            }
            return
        }
        // Target only the captured process; a global event could reach another
        // foreground app while activation is still being negotiated.
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        text.write(to: pasteboard)
        let ourChange = pasteboard.changeCount
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
        try performEditCommand("v", keyCode: kVK_ANSI_V)
        // Do not dismiss the preview if the editor silently ignored Paste.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if Self.attribute(element, kAXValueAttribute) as? String != fullValue { return }
            if let range = Self.selectedRange(element), range.length == 0,
               range.location != selection.location { return }
        }
        throw GrammyError("The editor did not paste the suggestion. Select the message again, or copy the suggestion.")
    }

    private func checkOriginalSelection() throws {
        guard let focused = Self.attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFEqual(focused, element),
              Self.attribute(element, kAXValueAttribute) as? String == fullValue,
              Self.attribute(element, kAXSelectedTextAttribute) as? String == original,
              let range = Self.selectedRange(element), range.location == selection.location,
              range.length == selection.length else {
            throw GrammyError("The draft, selection, or focused editor changed. Nothing was changed. Select the message again.")
        }
    }

    private func performEditCommand(_ key: String, keyCode: Int) throws {
        // An AX menu command invokes Copy/Paste in this app's responder chain,
        // including when macOS has not yet completed foreground activation.
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if let menu = Self.attribute(application, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() {
            var pending = [menu as! AXUIElement], matches: [AXUIElement] = [], visited = 0
            while let item = pending.popLast(), visited < 500 {
                visited += 1
                if Self.attribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole,
                   (Self.attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == key,
                   (Self.attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0,
                   Self.attribute(item, kAXEnabledAttribute) as? Bool == true { matches.append(item) }
                if let children = Self.attribute(item, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children) }
            }
            if matches.count == 1 {
                try checkOriginalSelection()
                if AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success { return }
            }
        }
        guard CGPreflightPostEventAccess() else {
            throw GrammyError("macOS is denying Grammy's keyboard event access. Refresh Grammy's existing Accessibility grant and select the message again.")
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            throw GrammyError("Could not invoke the source editor's command.")
        }
        try checkOriginalSelection()
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func restoreEditorFocus() {
        guard Self.attribute(element, kAXValueAttribute) as? String == fullValue,
              let range = Self.selectedRange(element), range.location == selection.location,
              range.length == selection.length else { return }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
