import Foundation
import Combine
import Security
import GrammyCore

@MainActor
final class GeminiAccount: ObservableObject {
    @Published private(set) var hasKey = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "geminiFallbackEnabled") }
    }
    @Published private(set) var isTesting = false
    @Published private(set) var message: String?
    private var testTask: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.grammy.gemini",
        kSecAttrAccount as String: "api-key"
    ]

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "geminiFallbackEnabled")
        // Query only existence at launch; retrieve the key only for an explicit request.
        var query = self.query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        hasKey = status == errSecSuccess
        if status != errSecSuccess && status != errSecItemNotFound {
            message = "Could not check the Gemini key in Keychain. Save it again or unlock your Keychain."
        }
    }

    var canFallback: Bool { isEnabled && hasKey }

    @discardableResult
    func save(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            message = "Enter a Google AI Studio API key without spaces."; return false
        }
        testTask?.cancel(); testTask = nil; isTesting = false
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var record = query
            record[kSecValueData as String] = Data(key.utf8)
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(record as CFDictionary, nil)
        }
        guard status == errSecSuccess else { message = "Could not save the Gemini key to Keychain."; return false }
        hasKey = true; isEnabled = true
        message = "Key saved in Keychain. Gemini fallback is enabled."
        return true
    }

    func remove() {
        testTask?.cancel(); testTask = nil; isTesting = false
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { message = "Could not remove the Gemini key from Keychain."; return }
        hasKey = false; isEnabled = false
        message = "Key removed. Gemini fallback is disabled."
    }

    func rewrite(original: String, previous: String?) async throws -> String {
        try Task.checkCancellation()
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw GrammyError("Could not read the Gemini key. Save it again in Settings or unlock your Keychain.")
        }
        let request = try Gemini.request(original: original, previous: previous, apiKey: key)
        try Task.checkCancellation()
        let (responseData, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let text = try Gemini.response(responseData, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        try Rewrite.validate(original: original, candidate: text)
        return text
    }

    func testConnection() {
        guard hasKey, !isTesting else { return }
        isTesting = true; message = "Testing gemini-3.5-flash-lite with a short sample…"
        testTask = Task {
            defer { if !Task.isCancelled { isTesting = false; testTask = nil } }
            do {
                _ = try await rewrite(original: "hey team, i will shares the update tomorrow 🙂", previous: nil)
                try Task.checkCancellation()
                message = "Connected to gemini-3.5-flash-lite. Sample rewrite and emoji check passed."
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
}
