import XCTest
@testable import GrammyCore

final class GeminiTests: XCTestCase {
    func testExactModelAndKeyInHeaderOnly() throws {
        let request = try Gemini.request(original: "hi team 🙂", previous: nil, apiKey: "test-key")
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertNil(request.url?.query)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-key"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(object["systemInstruction"])
        XCTAssertNil(object["safetySettings"])
    }

    func testRegenerationKeepsOriginalAndPreviousAlternative() throws {
        let request = try Gemini.request(original: "original", previous: "alternative", apiKey: "test-key")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual(contents[1]["role"] as? String, "model")
        XCTAssertEqual((contents[0]["parts"] as? [[String: String]])?.first?["text"], "original")
        XCTAssertEqual((contents[1]["parts"] as? [[String: String]])?.first?["text"], "alternative")
    }

    func testGeminiValidatesInputBeforeRequest() {
        XCTAssertThrowsError(try Gemini.request(original: "", previous: nil, apiKey: "key"))
        XCTAssertThrowsError(try Gemini.request(original: String(repeating: "x", count: 32_001), previous: nil, apiKey: "key"))
        XCTAssertThrowsError(try Gemini.request(original: "hello", previous: nil, apiKey: ""))
        XCTAssertThrowsError(try Gemini.request(original: "hello", previous: nil, apiKey: "line\nbreak"))
    }

    func testCompleteResponseExcludesThoughtParts() throws {
        let json = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Hidden reasoning","thought":true},{"text":"Hello "},{"text":"🙂"}]}}]}"#
        let result = try Gemini.response(Data(json.utf8), status: 200)
        XCTAssertEqual(result, "Hello 🙂")
        try Rewrite.validate(original: "hello 🙂", candidate: result)
    }

    func testTruncatedBlockedAndEmptyResponsesCannotBeAccepted() {
        for json in [
            #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}]}"#,
            #"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[{"text":"partial"}]}}]}"#,
            #"{"promptFeedback":{"blockReason":"SAFETY"}}"#,
            #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"thought","thought":true}]}}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"missing finish reason"}]}}]}"#,
            #"{"candidates":[]}"#
        ] { XCTAssertThrowsError(try Gemini.response(Data(json.utf8), status: 200)) }
    }

    func testProviderErrorsNeverEchoServerBody() {
        let body = Data(#"{"error":{"message":"sensitive server diagnostic"}}"#.utf8)
        for status in [400, 401, 403, 404, 429, 500] {
            XCTAssertThrowsError(try Gemini.response(body, status: status)) { error in
                XCTAssertFalse(error.localizedDescription.contains("sensitive server diagnostic"))
                if status == 404 { XCTAssertTrue(error.localizedDescription.contains("gemini-3.5-flash-lite")) }
            }
        }
    }

    func testFallbackPolicyDoesNotRetryCancellationRefusalOrInvalidOutput() {
        XCTAssertTrue(FallbackPolicy.allows(ProviderUnavailable("quota")))
        XCTAssertTrue(FallbackPolicy.allows(URLError(.timedOut)))
        XCTAssertFalse(FallbackPolicy.allows(CancellationError()))
        XCTAssertFalse(FallbackPolicy.allows(URLError(.cancelled)))
        XCTAssertFalse(FallbackPolicy.allows(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(FallbackPolicy.allows(GrammyError("refused")))
        var result = ResponseAccumulator()
        XCTAssertThrowsError(try result.consume(#"{"type":"response.refusal.done"}"#)) { error in
            XCTAssertFalse(FallbackPolicy.allows(error))
        }
    }

    @MainActor func testSuccessfulPrimaryNeverCallsFallback() async throws {
        var fallbackCalls = 0
        let output = try await RewriteRouter.run(primary: { "ChatGPT result" }, fallback: {
            fallbackCalls += 1; return "Gemini result"
        }, onFallback: { XCTFail("Should stay on ChatGPT") })
        XCTAssertEqual(output, "ChatGPT result")
        XCTAssertEqual(fallbackCalls, 0)
    }

    @MainActor func testUnavailablePrimaryUsesFallbackExactlyOnce() async throws {
        var primaryCalls = 0, fallbackCalls = 0, transitions = 0
        let output = try await RewriteRouter.run(primary: {
            primaryCalls += 1; throw ProviderUnavailable("not signed in")
        }, fallback: {
            fallbackCalls += 1; return "Gemini result"
        }, onFallback: { transitions += 1 })
        XCTAssertEqual(output, "Gemini result")
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertEqual(transitions, 1)
    }

    @MainActor func testDisabledFallbackPropagatesPrimaryFailure() async {
        do {
            _ = try await RewriteRouter.run(primary: { throw ProviderUnavailable("quota") }, fallback: nil,
                                            onFallback: { XCTFail("Fallback is disabled") })
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is ProviderUnavailable) }
    }

    @MainActor func testFallbackFailureDoesNotLoopOrReturnPartialPrimary() async {
        var calls = 0
        do {
            _ = try await RewriteRouter.run(primary: { throw ProviderUnavailable("network") }, fallback: {
                calls += 1; throw GrammyError("Gemini quota")
            }, onFallback: {})
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Gemini quota") }
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testCancelledRequestCannotStartFallback() async {
        let task = Task { @MainActor in
            try await RewriteRouter.run(primary: {
                withUnsafeCurrentTask { $0?.cancel() }
                throw ProviderUnavailable("interrupted")
            }, fallback: { XCTFail("Cancelled request must not send to Google"); return "unexpected" }, onFallback: {})
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
