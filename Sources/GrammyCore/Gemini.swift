import Foundation

/// Only availability failures may trigger another provider, never cancellation or rejected content.
public struct ProviderUnavailable: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum FallbackPolicy {
    public static func allows(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is ProviderUnavailable { return true }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(error.code)
    }
}

@MainActor
public enum RewriteRouter {
    public static func run(primary: () async throws -> String,
                           fallback: (() async throws -> String)?,
                           onFallback: () -> Void) async throws -> String {
        try Task.checkCancellation()
        do { return try await primary() }
        catch {
            try Task.checkCancellation()
            guard let fallback, FallbackPolicy.allows(error) else { throw error }
            onFallback()
            try Task.checkCancellation()
            return try await fallback()
        }
    }
}

public enum Gemini {
    public static let model = "gemini-3.5-flash-lite"
    public static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

    public static func request(original: String, previous: String?, apiKey: String) throws -> URLRequest {
        try Rewrite.validateInput(original)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains(where: { $0.isWhitespace }) else {
            throw GrammyError("Save a valid Google AI Studio API key in Settings first.")
        }
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": original]]]]
        if let previous, !previous.isEmpty {
            contents += [["role": "model", "parts": [["text": previous]]],
                         ["role": "user", "parts": [["text": Rewrite.alternativeInstruction]]]]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": Rewrite.instructions]]],
            "contents": contents,
            "generationConfig": ["candidateCount": 1, "maxOutputTokens": 8192]
        ])
        return request
    }

    public static func response(_ data: Data, status: Int) throws -> String {
        // Do not display provider error bodies; they can echo request data or credentials.
        guard (200..<300).contains(status) else {
            switch status {
            case 400, 401: throw GrammyError("Google AI Studio rejected the key or request. Check the saved API key.")
            case 403: throw GrammyError("This Google AI Studio key is not permitted to use the Gemini API. Check its project and API restrictions.")
            case 404: throw GrammyError("gemini-3.5-flash-lite is not available for this Google AI Studio project. No other model was substituted.")
            case 429: throw GrammyError("Google AI Studio’s quota or rate limit was reached. Check your project’s usage or try later.")
            default: throw GrammyError("Gemini could not process the request (HTTP \(status)). Try again.")
            }
        }
        guard data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrammyError("Gemini returned an unexpected response.")
        }
        if let feedback = object["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String, reason != "BLOCK_REASON_UNSPECIFIED" {
            throw GrammyError("Gemini declined this rewrite. Your draft is unchanged.")
        }
        guard let candidates = object["candidates"] as? [[String: Any]], candidates.count == 1,
              let candidate = candidates.first else { throw GrammyError("Gemini did not return a suggestion. Your draft is unchanged.") }
        guard candidate["finishReason"] as? String == "STOP" else {
            if candidate["finishReason"] as? String == "MAX_TOKENS" {
                throw GrammyError("Gemini’s suggestion was cut short. Select a shorter passage and try again.")
            }
            throw GrammyError("Gemini did not complete the rewrite. Your draft is unchanged.")
        }
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw GrammyError("Gemini returned no text.") }
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 128_000 else {
            throw GrammyError("Gemini returned an empty or unexpectedly long suggestion.")
        }
        return text
    }
}
