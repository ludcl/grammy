import XCTest
import AppKit
@testable import GrammyCore

final class FormattingTests: XCTestCase {
    func testRichCodeSurvivesRewriteAndClipboardRoundTrip() throws {
        let text = NSMutableAttributedString(string: "we should keeps stage and develop 😅")
        for word in ["stage", "develop"] {
            text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: (text.string as NSString).range(of: word))
        }
        let original = FormattedText(text)
        XCTAssertEqual(original.modelText, "we should keeps `stage` and `develop` 😅")
        let rewritten = try original.rewritten("We should keep `stage` and `develop` 😅")
        XCTAssertEqual(rewritten.string, "We should keep stage and develop 😅")
        XCTAssertTrue(rewritten.html.contains("<code>stage</code>"))
        XCTAssertTrue(rewritten.html.contains("<code>develop</code>"))
        XCTAssertThrowsError(try original.rewritten("We should keep `staging` and `develop` 😅"))
        XCTAssertThrowsError(try original.styled("We should keep staging and develop 😅"))
        let imported = try XCTUnwrap(FormattedText.importHTML(rewritten.html))
        let roundTrip = FormattedText(imported)
        XCTAssertEqual(roundTrip.string.trimmingCharacters(in: .newlines), rewritten.string)
        XCTAssertEqual(roundTrip.codeRanges.map { (roundTrip.string as NSString).substring(with: $0) }, ["stage", "develop"])
        let rtf = try rewritten.attributed.data(from: NSRange(location: 0, length: rewritten.attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(restored.string, rewritten.string)
    }
    func testStylesAndLinksDoNotBecomeYellowOrExpandOntoGeneratedWords() throws {
        let text = NSMutableAttributedString(string: "this are important, see docs")
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 15), range: (text.string as NSString).range(of: "important"))
        text.addAttribute(.link, value: URL(string: "https://example.com/docs")!, range: (text.string as NSString).range(of: "docs"))
        let candidate = try FormattedText(text).rewritten("This is important, see the docs")
        XCTAssertTrue(candidate.html.contains("<strong>important</strong>"))
        XCTAssertTrue(candidate.html.contains("<a href=\"https://example.com/docs\">docs</a>"))
        XCTAssertNil(candidate.attributed.attribute(.link, at: (candidate.string as NSString).range(of: "the").location, effectiveRange: nil))
        XCTAssertFalse(candidate.html.contains("background"))
    }
    func testServiceCapturesRichTextWithoutNativeAutomaticReplacement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let service = try XCTUnwrap((plist["NSServices"] as? [[String: Any]])?.first)
        XCTAssertEqual((service["NSSendTypes"] as? [String])?.first, NSPasteboard.PasteboardType.html.rawValue)
        XCTAssertEqual(Set(try XCTUnwrap(service["NSSendTypes"] as? [String])), Set([NSPasteboard.PasteboardType.html.rawValue, NSPasteboard.PasteboardType.rtf.rawValue, NSPasteboard.PasteboardType.string.rawValue]))
        XCTAssertNil(service["NSReturnTypes"], "Async previews must not let Services paste input, empty data, or incomplete suggestions into the source.")
        XCTAssertEqual(service["NSMessage"] as? String, "improveMessage")
    }

    func testSlackEmojiImagesAndCodeSurviveServicesInput() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hey team, i wont joins today  please keep stage and develop unchanged ", forType: .string)
        board.setString("<p>hey team, i wont joins today <img data-stringify-emoji='😅' alt=':sweat_smile:' src='https://invalid.example/emoji'> please keep <code>stage</code> and <code>develop</code> unchanged <img alt='&#x1F44D;' src='https://invalid.example/emoji'></p>", forType: .html)
        let original = try XCTUnwrap(FormattedText.read(board))
        XCTAssertEqual(Rewrite.emojis(in: original.string), ["😅", "👍"])
        XCTAssertEqual(original.codeRanges.map { (original.string as NSString).substring(with: $0) }, ["stage", "develop"])
        let rewritten = try original.rewritten("Hey team, I won’t join today 😅 please keep `stage` and `develop` unchanged 👍\n")
        XCTAssertNoThrow(try Rewrite.validate(original: original.string, candidate: rewritten.string))
        rewritten.write(to: board)
        let pasted = try XCTUnwrap(FormattedText.read(board))
        XCTAssertEqual(pasted.string, rewritten.string)
        XCTAssertTrue(pasted.html.contains("<code>stage</code>"))
        XCTAssertTrue(pasted.html.contains("<code>develop</code>"))
        XCTAssertEqual(Rewrite.emojis(in: pasted.string), ["😅", "👍"])
        XCTAssertFalse(pasted.html.contains("background"))
    }

    func testLossyRTFCannotDropPlainTextEmoji() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSMutableAttributedString(string: "keep stage  today")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: (rich.string as NSString).range(of: "stage"))
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(data, forType: .rtf)
        board.setString("keep stage 😅 today", forType: .string)
        let value = try XCTUnwrap(FormattedText.read(board))
        XCTAssertEqual(value.string, "keep stage 😅 today")
        XCTAssertTrue(value.html.contains("<code>stage</code>"))
    }

    func testNativeSlackClipboardPreservesCodeAndEmojiObjectsThroughRewrite() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "slack-texty", withExtension: "pickle", subdirectory: "Fixtures"))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let plain = "hey team, i wont joins today please keep stage and develop unchanged :thumbsup::skin-tone-3::sweat_smile:"
        board.setString(plain, forType: .string)
        board.setData(try Data(contentsOf: fixture), forType: ChromiumClipboard.type)
        let original = try XCTUnwrap(FormattedText.read(board))
        XCTAssertEqual(original.string, plain)
        XCTAssertEqual(original.codeRanges.map { (plain as NSString).substring(with: $0) }, ["stage", "develop"])
        XCTAssertTrue(original.modelText.contains("`stage` and `develop`"))
        let response = "Hey team, I won’t join today. Please keep `stage` and `develop` unchanged :thumbsup::skin-tone-3::sweat_smile:"
        let replacement = try original.rewritten(response)
        XCTAssertNoThrow(try Rewrite.validate(original: original.string, candidate: replacement.string))
        replacement.write(to: board)
        let pasted = try XCTUnwrap(FormattedText.read(board))
        XCTAssertEqual(pasted.string, replacement.string)
        XCTAssertEqual(pasted.codeRanges.count, 2)
        let custom = try XCTUnwrap(ChromiumClipboard.decode(try XCTUnwrap(board.data(forType: ChromiumClipboard.type))))
        let json = try XCTUnwrap(custom["slack/texty"]?.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let ops = try XCTUnwrap(object["ops"] as? [[String: Any]])
        let labels = ops.compactMap { (($0["insert"] as? [String: Any])?["slackemoji"] as? [String: Any])?["text"] as? String }
        XCTAssertEqual(labels, [":thumbsup::skin-tone-3:", ":sweat_smile:"])
        XCTAssertFalse(pasted.html.contains("background"))
    }

    func testUntrustedCustomClipboardCannotReplaceDifferentPlainText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("keep this 😅", forType: .string)
        let delta = "{\"ops\":[{\"insert\":\"different message\",\"attributes\":{\"code\":true}}]}"
        board.setData(ChromiumClipboard.encode(["slack/texty": delta]), forType: ChromiumClipboard.type)
        XCTAssertEqual(FormattedText.read(board)?.string, "keep this 😅")
        XCTAssertTrue(FormattedText.read(board)?.codeRanges.isEmpty == true)
        let valid = ChromiumClipboard.encode(["slack/texty": delta])
        for length in [0, 4, 8, valid.count - 1] {
            XCTAssertNil(ChromiumClipboard.decode(Data(valid.prefix(length))))
        }
        XCTAssertNil(ChromiumClipboard.decode(Data(repeating: 255, count: 16)))
    }

    func testCustomEmojiLabelsAndComplexUnicodeAreRetained() throws {
        let value = try XCTUnwrap(FormattedText.importHTML("<b>hi</b> <img alt='👩🏽‍💻'> <img alt=':custom_party:'> <img alt='photo' src='https://invalid.example/image'>"))
        XCTAssertEqual(value.string, "hi 👩🏽‍💻 :custom_party: ")
        XCTAssertTrue(FormattedText(value).html.contains("<strong>hi</strong>"))
    }
    func testClipboardSpansRetainCodeAndEmphasis() throws {
        let html = "keep <span style='font-family: monospace'>stage</span> and <span style='font-weight: 700; font-style: italic'>develop</span>"
        let value = FormattedText(try XCTUnwrap(FormattedText.importHTML(html)))
        XCTAssertEqual(value.modelText, "keep `stage` and develop")
        XCTAssertTrue(value.html.contains("<code>stage</code>"))
        XCTAssertTrue(value.html.contains("<em><strong>develop</strong></em>"))
    }
    func testUnlabeledEmojiAttachmentsAreNotSentToProviders() {
        XCTAssertThrowsError(try Rewrite.validateInput("hey \u{fffc}"))
        XCTAssertNoThrow(try Rewrite.validateInput("hey 😅"))
    }

    func testMarkdownCodeCannotBeRemovedOrChanged() throws {
        XCTAssertThrowsError(try Rewrite.validate(original: "keep `stage`", candidate: "Keep stage"))
        XCTAssertThrowsError(try Rewrite.validate(original: "keep `stage`", candidate: "Keep `staging`"))
        XCTAssertNoThrow(try Rewrite.validate(original: "keeps ```let x = 1```", candidate: "Keep ```let x = 1```"))
    }
    func testWordHighlightsAndUnicodeRanges() {
        let original = "hey, i wont joins 😅 develop"
        let suggestion = "Hey, I won’t join 😅 develop"
        let ranges = TextDiff.changedRanges(original: original, suggestion: suggestion)
        XCTAssertEqual(ranges.map { (suggestion as NSString).substring(with: $0) }, ["Hey", "I", "won’t", "join"])
        XCTAssertTrue(TextDiff.changedRanges(original: original, suggestion: original).isEmpty)
        XCTAssertTrue(TextDiff.changedRanges(original: "a b", suggestion: "a").isEmpty) // deletions have no target span
    }
    func testPlainMarkdownIsNotConvertedToRichCodeOrLost() throws {
        let original = FormattedText("keeps `stage` and **develop** 🙂")
        let candidate = try original.rewritten("Keep `stage` and **develop** 🙂")
        XCTAssertEqual(candidate.string, "Keep `stage` and **develop** 🙂")
        XCTAssertTrue(candidate.codeRanges.isEmpty)
    }
    func testImportedHTMLKeepsSemanticCodeAndDoesNotLoadResources() throws {
        let html = "<html><head><link rel='stylesheet' href='https://invalid.example/style'></head><body>keep <code>stage</code> <b>please</b><img src='https://invalid.example/image'></body></html>"
        let value = FormattedText(try XCTUnwrap(FormattedText.importHTML(html)))
        XCTAssertEqual(value.string.trimmingCharacters(in: .newlines), "keep stage please")
        XCTAssertTrue(value.modelText.contains("`stage`"))
        XCTAssertTrue(value.html.contains("<strong>please</strong>"))
    }
}
