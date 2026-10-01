import AppKit
import ApplicationServices
import XCTest
import GrammyCore
@testable import Grammy

final class RewriteFlowTests: XCTestCase {
    @MainActor
    func testServiceCorrectsAnEchoAutomaticallyWithoutRegenerate() async throws {
        _ = NSApplication.shared
        let draft = "hey team I wont be joinning today :crying-cat-wobbly: please keep stage and develop unchanged :pray::skin-tone-3:"
        let rich = NSMutableAttributedString(string: draft)
        for word in ["stage", "develop"] {
            rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: (draft as NSString).range(of: word))
        }
        let format = FormattedText(rich)
        let corrected = draft.replacingOccurrences(of: "wont be joinning", with: "won't be joining")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(draft, forType: .string)
        var requests = 0
        var replacement: FormattedText?
        var model: RewriteModel!
        model = RewriteModel { original, previous in
            requests += 1
            XCTAssertEqual(original, format.modelText)
            if requests == 1 {
                XCTAssertNil(previous)
                return original + "\n"
            }
            XCTAssertEqual(previous, original + "\n")
            XCTAssertTrue(model.isBusy)
            XCTAssertFalse(model.isComplete)
            XCTAssertFalse(model.canAccept)
            return original.replacingOccurrences(of: "wont be joinning", with: "won't be joining")
        }
        let delegate = AppDelegate(model: model, serviceCapture: { _ in
            (format, "Test editor", { replacement = $0 })
        })
        var error: NSString?
        delegate.improveMessage(board, userData: nil, error: &error)
        for _ in 0..<1000 {
            if model.canAccept { break }
            await Task.yield()
        }
        XCTAssertNil(error)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.suggestion, corrected)
        XCTAssertTrue(model.canAccept)
        XCTAssertNil(replacement)
        XCTAssertEqual(board.string(forType: .string), draft)
        model.accept()
        while model.isReplacing { await Task.yield() }
        let accepted = try XCTUnwrap(replacement)
        XCTAssertTrue(accepted.html.contains("<code>stage</code>"))
        XCTAssertTrue(accepted.html.contains("<code>develop</code>"))
        XCTAssertEqual(Rewrite.shortcodes(in: accepted.string), Rewrite.shortcodes(in: draft))
    }

    @MainActor
    func testUnchangedCorrectDraftStopsAfterOneAutomaticFollowUp() async {
        var requests = 0
        let model = RewriteModel { original, _ in requests += 1; return original }
        model.prepare("Thanks, team! 🙂", source: "Test")
        model.generate()
        while model.isBusy { await Task.yield() }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.suggestion, "Thanks, team! 🙂")
        XCTAssertTrue(model.canAccept)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testCancellationAfterEchoPreventsAutomaticFollowUp() async {
        var requests = 0
        let model = RewriteModel { original, _ in
            requests += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return original
        }
        model.prepare("hey 🙂", source: "Test")
        model.generate()
        while model.isBusy { await Task.yield() }
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.canAccept)
        XCTAssertFalse(model.isComplete)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testCancelledFollowUpCannotOverwriteNewSelection() async {
        var pending: CheckedContinuation<String, Never>?
        let model = RewriteModel { original, previous in
            if previous == nil { return original }
            return await withCheckedContinuation { pending = $0 }
        }
        model.prepare("hey 🙂", source: "Test")
        model.generate()
        while pending == nil { await Task.yield() }
        model.cancel()
        model.prepare("new draft 😅", source: "New selection")
        pending?.resume(returning: "Hey 🙂")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.original, "new draft 😅")
        XCTAssertEqual(model.suggestion, "")
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isComplete)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testAutomaticFollowUpFailureDoesNotAcceptEcho() async {
        var requests = 0
        let model = RewriteModel { original, previous in
            requests += 1
            if previous == nil { return original }
            throw GrammyError("Request failed")
        }
        model.prepare("hey 🙂", source: "Test")
        model.generate()
        while model.isBusy { await Task.yield() }
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(model.canAccept)
        XCTAssertFalse(model.isComplete)
        XCTAssertEqual(model.error, "Request failed")
    }

    @MainActor
    func testInvalidFollowUpCannotBeAccepted() async {
        var requests = 0
        let model = RewriteModel { original, previous in
            requests += 1
            return previous == nil ? original : "Hey 😅"
        }
        model.prepare("hey 🙂", source: "Test")
        model.generate()
        while model.isBusy { await Task.yield() }
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(model.canAccept)
        XCTAssertFalse(model.isComplete)
        XCTAssertTrue(model.error?.contains("emoji") == true)
    }

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
