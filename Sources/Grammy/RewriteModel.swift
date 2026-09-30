import AppKit
import GrammyCore

@MainActor
final class RewriteModel: ObservableObject {
    @Published var original = ""
    @Published var suggestion = ""
    @Published var error: String?
    @Published var isBusy = false
    @Published var isReplacing = false
    @Published var isComplete = false
    @Published var isSample = false
    @Published var sourceName = "Your message"
    @Published var hasTarget = false
    @Published var providerName = ""
    @Published var usedFallback = false
    var replaceAction: ((String) async throws -> Void)?
    var cancelAction: (() -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let account: ChatGPTAccount
    private let gemini: GeminiAccount
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    init(account: ChatGPTAccount, gemini: GeminiAccount) { self.account = account; self.gemini = gemini }
    var canAccept: Bool { isComplete && !isBusy && !isReplacing && (try? Rewrite.validate(original: original, candidate: suggestion)) != nil }
    var emojiWarning: String? {
        guard isComplete else { return nil }
        do { try Rewrite.validate(original: original, candidate: suggestion); return nil }
        catch { return error.localizedDescription }
    }

    func prepare(_ text: String, source: String, replace: ((String) async throws -> Void)? = nil) {
        stop()
        original = text; suggestion = ""; sourceName = source
        isComplete = false; isSample = false; error = nil; providerName = ""; usedFallback = false
        hasTarget = replace != nil; replaceAction = replace
    }

    func generate() {
        guard !isBusy && !isReplacing else { return }
        let original = self.original
        let previous = isComplete && !isSample ? suggestion : nil
        isSample = false; isComplete = false; suggestion = ""; error = nil
        isBusy = true
        let id = UUID(); generation = id
        task = Task {
            defer { if generation == id { isBusy = false; task = nil } }
            do {
                try Rewrite.validateInput(original)
                providerName = "ChatGPT"; usedFallback = false
                var fallback: (() async throws -> String)?
                if gemini.canFallback {
                    fallback = { [self] in
                        guard gemini.canFallback else { throw GrammyError("Gemini fallback was disabled. Try again.") }
                        return try await gemini.rewrite(original: original, previous: previous)
                    }
                }
                let text = try await RewriteRouter.run(primary: { [self] in
                    try await rewriteWithChatGPT(original: original, previous: previous, id: id)
                }, fallback: fallback, onFallback: { [self] in
                    suggestion = "" // Discard any partial ChatGPT output before trying Gemini.
                    providerName = "Gemini 3.5 Flash-Lite"; usedFallback = true
                })
                try Task.checkCancellation()
                guard generation == id else { return }
                suggestion = text
                isComplete = true
                try Rewrite.validate(original: original, candidate: suggestion)
            } catch is CancellationError { }
            catch { if generation == id { self.error = error.localizedDescription } }
        }
    }

    private func rewriteWithChatGPT(original: String, previous: String?, id: UUID) async throws -> String {
        guard account.isSignedIn else { throw ProviderUnavailable("ChatGPT is not connected.") }
        if account.models.isEmpty { await account.loadModels() }
        guard !account.selectedModel.isEmpty else { throw ProviderUnavailable("No ChatGPT model is available. Check Settings.") }
        let body = try Rewrite.body(original: original, previous: previous, model: account.selectedModel)
        let token: String
        do { token = try await account.accessToken() }
        catch {
            try Task.checkCancellation()
            throw ProviderUnavailable("Your ChatGPT connection is unavailable. Reconnect in Settings.")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw GrammyError("ChatGPT returned an unexpected response.") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw ProviderUnavailable("Your ChatGPT sign-in expired. Reconnect in Settings.")
            case 403: throw ProviderUnavailable("Your account or Enterprise workspace does not allow this request. Check its app permissions.")
            case 429: throw ProviderUnavailable("Your ChatGPT usage limit was reached. Check ChatGPT Settings → Usage or try later.")
            case 500...599: throw ProviderUnavailable("ChatGPT is temporarily unavailable.")
            default: throw GrammyError("ChatGPT could not process the request (HTTP \(http.statusCode)). Try again.")
            }
        }
        var parser = SSEParser(), result = ResponseAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            if let event = parser.feed(line) {
                try result.consume(event)
                guard result.text.utf8.count <= 128_000 else { throw GrammyError("The suggestion was unexpectedly long. Try a shorter selection.") }
                suggestion = result.text
                if result.completed { break }
            }
        }
        if let event = parser.flush() { try result.consume(event) }
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        return try result.result()
    }

    func accept() {
        guard canAccept else { return }
        guard let replaceAction else { copy(); return }
        isReplacing = true; error = nil
        task = Task {
            defer { isReplacing = false; task = nil }
            do { try await replaceAction(suggestion) }
            catch { self.error = error.localizedDescription }
        }
    }
    func copy() {
        guard canAccept else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(suggestion, forType: .string)
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; isBusy = false; isReplacing = false }
    func cancel() { stop(); cancelAction?() }
    func sample() {
        prepare("hey team, i wont be able to joins the standup today 😅\nwill share my updates here after lunch :thumbsup:", source: "Sample message")
        suggestion = "Hey team, I won’t be able to join the standup today 😅\nI’ll share my updates here after lunch :thumbsup:"
        isSample = true; isComplete = true
    }
}
