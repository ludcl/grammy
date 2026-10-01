import SwiftUI
import AppKit
import GrammyCore

/// Temporary layout attributes show the diff without putting yellow into copied/pasted text.
struct FormattedEditor: NSViewRepresentable {
    var value: FormattedText
    var original: String
    var highlight: Bool = false
    var editable: Bool = false
    var onEdit: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isGrammarCheckingEnabled = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? NSTextView else { return }
        text.isEditable = editable
        text.isSelectable = true
        // Display normalized colors/sizes while retaining semantic font traits and links.
        let display = NSMutableAttributedString(attributedString: value.attributed)
        let all = NSRange(location: 0, length: display.length)
        display.removeAttribute(.backgroundColor, range: all)
        display.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        display.addAttribute(.paragraphStyle, value: paragraph, range: all)
        value.attributed.enumerateAttribute(.font, in: all) { font, range, _ in
            let traits = (font as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var chosen = traits.contains(.monoSpace) ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 15)
            if traits.contains(.bold) { chosen = NSFontManager.shared.convert(chosen, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { chosen = NSFontManager.shared.convert(chosen, toHaveTrait: .italicFontMask) }
            display.addAttribute(.font, value: chosen, range: range)
        }
        if text.textStorage?.isEqual(to: display) != true {
            let selection = text.selectedRange()
            context.coordinator.updating = true
            text.textStorage?.setAttributedString(display)
            text.setSelectedRange(NSRange(location: min(selection.location, display.length), length: min(selection.length, max(0, display.length - selection.location))))
            context.coordinator.updating = false
        }
        text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        if highlight {
            for range in TextDiff.changedRanges(original: original, suggestion: value.string) {
                text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(calibratedRed: 1, green: 0.88, blue: 0.40, alpha: 0.38), forCharacterRange: range)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FormattedEditor
        var updating = false
        init(_ parent: FormattedEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let text = notification.object as? NSTextView else { return }
            parent.onEdit?(text.string)
        }
    }
}
