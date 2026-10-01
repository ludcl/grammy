import AppKit
import ApplicationServices
import XCTest
import GrammyCore
@testable import Grammy

final class RewriteFlowTests: XCTestCase {
    @MainActor
    func testServiceMatchesSlackSelectionWithFlattenedParagraphs() {
        let target = TextTarget(app: .current,
                                element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                                original: "hey team, i wont joins today \u{fffc}please keep stage and develop unchanged ",
                                fullValue: "", selection: CFRange(location: 0, length: 90))
        XCTAssertTrue(target.matchesServiceInput(FormattedText("hey team, i wont joins today \u{fffc}\n\nplease keep stage and develop unchanged \u{fffc}")))
        XCTAssertTrue(target.matchesServiceInput(FormattedText("hey team, i wont joins today 😅\nplease keep stage and develop unchanged 👍")))
        XCTAssertFalse(target.matchesServiceInput(FormattedText("hey team, i wont joins tomorrow 😅\nplease keep stage and develop unchanged 👍")))
    }

    @MainActor
    func testPreparedInputGeneratesAndAcceptsFormattedSuggestion() async throws {
        let original = formattedDraft()
        var requests = 0
        let model = RewriteModel { text, previous in
            requests += 1
            XCTAssertEqual(text, "hey team, i wont joins today 😅 keep `stage` and `develop` 👍")
            XCTAssertNil(previous)
            return "Hey team, I won’t join today 😅 keep `stage` and `develop` 👍"
        }
        var accepted: FormattedText?
        model.prepare(original, source: "Test") { accepted = $0 }
        model.generate()
        while model.isBusy { await Task.yield() }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.canAccept)
        model.accept()
        while model.isReplacing { await Task.yield() }
        let result = try XCTUnwrap(accepted)
        XCTAssertTrue(result.html.contains("<code>stage</code>"))
        XCTAssertTrue(result.html.contains("<code>develop</code>"))
        XCTAssertEqual(Rewrite.emojis(in: result.string), ["😅", "👍"])
        XCTAssertFalse(result.html.contains("background"))
    }

    @MainActor
    func testOnlyUserEditsInvalidateSuggestions() async {
        let model = RewriteModel { _, _ in "Hey 😅" }
        model.prepare("hey 😅", source: "Test")
        model.generate()
        model.editOriginal("hey 😅") // A deferred view update must not clear the request.
        while model.isBusy { await Task.yield() }
        XCTAssertTrue(model.canAccept)
        model.editOriginal("hello 😅")
        XCTAssertFalse(model.isComplete)
        XCTAssertEqual(model.suggestion, "")
    }

    @MainActor
    func testServiceAutomaticallyRequestsAndReplacesOnlyAfterAccept() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hey 😅", forType: .string)
        var requests = 0
        var replacement: FormattedText?
        let model = RewriteModel { _, _ in requests += 1; return "Hey 😅" }
        let delegate = AppDelegate(model: model, serviceCapture: { input in
            (input, "Test editor", { replacement = $0 })
        })
        var error: NSString?
        delegate.improveMessage(board, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(board.string(forType: .string), "hey 😅")
        for _ in 0..<1000 {
            if model.canAccept { break }
            await Task.yield()
        }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.canAccept)
        XCTAssertNil(replacement)
        model.accept()
        while model.isReplacing { await Task.yield() }
        XCTAssertEqual(replacement?.string, "Hey 😅")
        XCTAssertEqual(board.string(forType: .string), "hey 😅")
    }

    @MainActor
    func testServiceCancelNeverReplacesSelection() async {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hey 😅", forType: .string)
        let model = RewriteModel { _, _ in "Hey 😅" }
        let delegate = AppDelegate(model: model, serviceCapture: { input in
            (input, "Test editor", { _ in XCTFail("Cancel must not replace the draft") })
        })
        var error: NSString?
        delegate.improveMessage(board, userData: nil, error: &error)
        XCTAssertNil(error)
        for _ in 0..<1000 {
            if model.canAccept { break }
            await Task.yield()
        }
        XCTAssertTrue(model.canAccept)
        model.cancel()
        XCTAssertEqual(board.string(forType: .string), "hey 😅")
    }

    @MainActor
    func testFailedEmojiCaptureDoesNotRequestIncompleteText() async {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hey \u{fffc}", forType: .string)
        let model = RewriteModel { _, _ in XCTFail("Incomplete text must not reach the provider"); return "Hey" }
        let delegate = AppDelegate(model: model, serviceCapture: { _ in
            throw GrammyError("The editor did not regain focus.")
        })
        var error: NSString?
        delegate.improveMessage(board, userData: nil, error: &error)
        for _ in 0..<1000 {
            if model.error != nil { break }
            await Task.yield()
        }
        XCTAssertNil(error)
        XCTAssertFalse(model.canAccept)
        XCTAssertTrue(model.error?.contains("did not regain focus") == true)
        model.cancel()
    }

    @MainActor
    func testRejectedServiceLeavesItsInputUntouched() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hey", forType: .string)
        let model = RewriteModel { _, _ in XCTFail("A rejected request must not generate"); return "Hey" }
        model.isBusy = true
        let delegate = AppDelegate(model: model)
        var error: NSString?
        delegate.improveMessage(board, userData: nil, error: &error)
        XCTAssertNotNil(error)
        XCTAssertEqual(board.string(forType: .string), "hey")
    }
}

private func formattedDraft() -> FormattedText {
    let text = NSMutableAttributedString(string: "hey team, i wont joins today 😅 keep stage and develop 👍")
    for word in ["stage", "develop"] {
        text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: (text.string as NSString).range(of: word))
    }
    return FormattedText(text)
}
