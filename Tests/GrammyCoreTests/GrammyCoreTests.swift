import XCTest
import Security
@testable import GrammyCore

final class GrammyCoreTests: XCTestCase {
    func testEmojiPreservationIncludesComplexGraphemes() throws {
        let original = "im here 👩🏽‍💻 🇨🇦 👨‍👩‍👧‍👦 1️⃣ ❤️ :thumbsup:"
        try Rewrite.validate(original: original, candidate: "I’m here 👩🏽‍💻 🇨🇦 👨‍👩‍👧‍👦 1️⃣ ❤️ :thumbsup:")
        XCTAssertThrowsError(try Rewrite.validate(original: original, candidate: "I’m here 👩🏻‍💻 🇨🇦 👨‍👩‍👧‍👦 1️⃣ ❤️ :thumbsup:"))
        XCTAssertThrowsError(try Rewrite.validate(original: "hello 🙂 🙂", candidate: "Hello 🙂"))
        XCTAssertThrowsError(try Rewrite.validate(original: "hello :party_parrot:", candidate: "Hello :parrot:"))
        XCTAssertEqual(Rewrite.emojis(in: "Meet at 12 #channel *bold*"), [])
    }

    func testEmptyAndOversizedDraftsRejected() {
        XCTAssertThrowsError(try Rewrite.body(original: " \n ", previous: nil, model: "test"))
        XCTAssertThrowsError(try Rewrite.body(original: String(repeating: "x", count: 32_001), previous: nil, model: "test"))
        XCTAssertThrowsError(try Rewrite.validate(original: "hello", candidate: ""))
    }

    func testRegenerationAnchorsToOriginalAndOnlyLatestAlternative() throws {
        let body = try Rewrite.body(original: "hi team 😅", previous: "Hi team 😅", model: "available-model")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(object["input"] as? [[String: String]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["content"], "hi team 😅")
        XCTAssertEqual(input[1]["content"], "Hi team 😅")
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertEqual(object["stream"] as? Bool, true)
        for unsupported in ["temperature", "max_output_tokens", "previous_response_id", "conversation", "tools"] {
            XCTAssertNil(object[unsupported])
        }
    }

    func testSSERequiresCompletedEvent() throws {
        var parser = SSEParser(), accumulator = ResponseAccumulator()
        let lines = [": heartbeat", "event: response.output_text.delta", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello 🙂\"}", "", "data: [DONE]", ""]
        for line in lines { if let event = parser.feed(line) { try accumulator.consume(event) } }
        XCTAssertEqual(accumulator.text, "Hello 🙂")
        XCTAssertThrowsError(try accumulator.result())
        try accumulator.consume(#"{"type":"response.completed"}"#)
        XCTAssertEqual(try accumulator.result(), "Hello 🙂")
    }

    func testFailedEventAfterPartialTextNeverReturnsSuccess() throws {
        var accumulator = ResponseAccumulator()
        try accumulator.consume(#"{"type":"response.output_text.delta","delta":"Partial"}"#)
        XCTAssertThrowsError(try accumulator.consume(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("allowance"))
        }
        XCTAssertFalse(accumulator.completed)
        XCTAssertThrowsError(try accumulator.result())
    }

    func testMultilineEventAndFinalFlush() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed("data: first"))
        XCTAssertNil(parser.feed("data: second"))
        XCTAssertEqual(parser.feed(""), "first\nsecond")
        XCTAssertNil(parser.feed("data:last"))
        XCTAssertEqual(parser.flush(), "last")
        XCTAssertNil(parser.flush())
    }

    func testPKCEKnownRFCVector() {
        XCTAssertEqual(OAuthSupport.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCallbackRejectsMismatchedStateAndRegistration() throws {
        let valid = URL(string: "http://127.0.0.1:1234/auth/callback?state=expected&code=abc&client_id=oaiapp_new")!
        let result = try OAuthSupport.callback(valid, state: "expected", clientID: nil)
        XCTAssertEqual(result.client, "oaiapp_new")
        XCTAssertEqual(result.code, "abc")
        XCTAssertThrowsError(try OAuthSupport.callback(valid, state: "other", clientID: nil))
        XCTAssertThrowsError(try OAuthSupport.callback(valid, state: "expected", clientID: "oaiapp_old"))
        let duplicate = URL(string: "http://127.0.0.1/auth/callback?state=expected&state=expected&code=abc&client_id=x")!
        XCTAssertThrowsError(try OAuthSupport.callback(duplicate, state: "expected", clientID: nil))
        let denied = URL(string: "http://127.0.0.1/auth/callback?state=expected&error=access_denied")!
        XCTAssertThrowsError(try OAuthSupport.callback(denied, state: "expected", clientID: nil))
        let returning = URL(string: "http://127.0.0.1/auth/callback?state=expected&code=abc")!
        XCTAssertEqual(try OAuthSupport.callback(returning, state: "expected", clientID: "registered").client, "registered")
        XCTAssertThrowsError(try OAuthSupport.callback(returning, state: "expected", clientID: nil))
    }

    func testFormEscapesReservedCharacters() {
        let data = OAuthSupport.form(["code": "a+b&c=d", "scope": "openid email"])
        XCTAssertEqual(String(data: data, encoding: .utf8), "code=a%2Bb%26c%3Dd&scope=openid%20email")
    }

    func testJWTSignatureAndClaims() throws {
        // Public test vectors; their throwaway private key was discarded during fixture generation.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "oidc", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let jwks = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["jwks"]))
        let token = try XCTUnwrap(fixture["valid"] as? String)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try IDTokenVerifier.verify(token, jwks: jwks, clientID: "client", nonce: "nonce", now: now).subject, "subject")
        XCTAssertThrowsError(try IDTokenVerifier.verify(token, jwks: jwks, clientID: "other", nonce: "nonce", now: now))
        XCTAssertThrowsError(try IDTokenVerifier.verify(token, jwks: jwks, clientID: "client", nonce: "other", now: now))
        XCTAssertThrowsError(try IDTokenVerifier.verify(token, jwks: jwks, clientID: "client", nonce: "nonce", now: now.addingTimeInterval(200)))
        let wrongIssuer = try XCTUnwrap(fixture["wrongIssuer"] as? String)
        XCTAssertThrowsError(try IDTokenVerifier.verify(wrongIssuer, jwks: jwks, clientID: "client", nonce: "nonce", now: now))
        let parts = token.split(separator: ".")
        let tampered = parts.prefix(2).joined(separator: ".") + "." + OAuthSupport.base64url(Data(repeating: 0, count: 256))
        XCTAssertThrowsError(try IDTokenVerifier.verify(tampered, jwks: jwks, clientID: "client", nonce: "nonce", now: now))
    }
}
