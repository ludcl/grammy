import AppKit
import Foundation
import Network
import Security
import GrammyCore

private enum CredentialStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.grammy.chatgpt", kSecAttrAccount as String: "active-account"]
    static func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GrammyError("Could not read Grammy’s account from Keychain.") }
        return result as? Data
    }
    static func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GrammyError("Could not save sign-in securely to Keychain.") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GrammyError("Could not remove Grammy’s sign-in from Keychain.")
        }
    }
}

private struct Credentials: Codable {
    var clientID: String
    var subject: String
    var email: String?
    var accessToken: String
    var refreshToken: String?
    var idToken: String
    var scopes: [String]
    var expiresAt: Date
}

struct AvailableModel: Identifiable, Decodable {
    var slug: String
    var display_name: String
    var visibility: String?
    var id: String { slug }
}

@MainActor
final class ChatGPTAccount: ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published private(set) var models: [AvailableModel] = []
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    private var credentials: Credentials?
    private var authTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private var listener: LoopbackCallback?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    private let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private let resource = "https://api.openai.com/v1"

    init() {
        selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        do {
            if let data = try CredentialStore.read() {
                let saved = try JSONDecoder().decode(Credentials.self, from: data)
                credentials = saved
                isSignedIn = true
                email = saved.email ?? "ChatGPT account"
            }
        } catch { message = error.localizedDescription }
    }

    func signIn(differentAccount: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        message = "Complete sign-in in your browser. Choose the workspace you want Grammy to use."
        authTask = Task {
            defer { listener?.stop(); listener = nil; isBusy = false; authTask = nil }
            do {
                let defaults = UserDefaults.standard
                let hostID = defaults.string(forKey: "hostID") ?? "urn:uuid:\(UUID().uuidString.lowercased())"
                defaults.set(hostID, forKey: "hostID")
                let client = differentAccount ? nil : defaults.string(forKey: "clientID")
                let expectedSubject = differentAccount ? nil : defaults.string(forKey: "subject")
                let state = try OAuthSupport.random(), nonce = try OAuthSupport.random(), verifier = try OAuthSupport.random()
                let callback = LoopbackCallback(expectedState: state)
                listener = callback
                let redirect = try await callback.start()
                var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
                var fields = [
                    "client_id": client ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                    "response_type": "code", "redirect_uri": redirect.absoluteString,
                    "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                    "resource": resource, "state": state, "nonce": nonce,
                    "code_challenge_method": "S256", "code_challenge": OAuthSupport.challenge(verifier)
                ]
                if client == nil { fields["agent_name_hint"] = "Grammy" }
                if !differentAccount, let credentials {
                    fields["id_token_hint"] = credentials.idToken
                    fields["login_hint"] = credentials.email
                }
                components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = components.url, NSWorkspace.shared.open(url) else {
                    throw GrammyError("Could not open the sign-in page in your browser.")
                }
                let returnedURL = try await callback.wait()
                try Task.checkCancellation()
                let result = try OAuthSupport.callback(returnedURL, state: state, clientID: client)
                let tokens = try await tokenRequest([
                    "grant_type": "authorization_code", "client_id": result.client,
                    "code": result.code, "code_verifier": verifier,
                    "redirect_uri": redirect.absoluteString, "resource": resource
                ])
                guard let idToken = tokens["id_token"] as? String else { throw GrammyError("ChatGPT did not return a verified identity.") }
                let identity = try await verify(idToken, client: result.client, nonce: nonce)
                if let expectedSubject, identity.subject != expectedSubject {
                    throw GrammyError("This sign-in belongs to another account. Use ‘Use another account’ instead.")
                }
                let saved = try makeCredentials(tokens, client: result.client, identity: identity, idToken: idToken)
                try Task.checkCancellation()
                try save(saved)
                defaults.set(saved.clientID, forKey: "clientID")
                defaults.set(saved.subject, forKey: "subject")
                selectedModel = ""
                message = "Connected. Rewrites use your ChatGPT plan allowance."
                await loadModels()
            } catch is CancellationError { message = "Sign-in cancelled." }
            catch { message = error.localizedDescription }
        }
    }

    func cancelSignIn() { authTask?.cancel(); listener?.stop() }

    func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        refreshTask?.cancel()
        if let refreshTask { _ = try? await refreshTask.value }
        self.refreshTask = nil
        let saved = credentials
        var revoked = saved?.refreshToken == nil
        if let saved, let refresh = saved.refreshToken {
            do {
                let discovery = try await json(URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
                if let endpoint = discovery["revocation_endpoint"] as? String,
                   let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = OAuthSupport.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": saved.clientID])
                    let (_, response) = try await session.data(for: request)
                    revoked = (response as? HTTPURLResponse)?.statusCode == 200
                }
            } catch { revoked = false }
        }
        do {
            try CredentialStore.delete()
            credentials = nil; email = nil; isSignedIn = false; models = []; selectedModel = ""
            message = revoked ? "Signed out." : "Signed out locally. Remote disconnection was not confirmed; disconnect Grammy in ChatGPT Settings."
        } catch { message = error.localizedDescription }
    }

    func accessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        guard let saved = credentials else { throw GrammyError("Connect your ChatGPT account in Settings first.") }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        guard let refresh = saved.refreshToken else { throw GrammyError("Please sign in again to renew your ChatGPT connection.") }
        let task = Task<String, Error> {
            let tokens = try await tokenRequest(["grant_type": "refresh_token", "client_id": saved.clientID,
                "refresh_token": refresh, "resource": resource])
            var updated = saved
            guard let access = tokens["access_token"] as? String, !access.isEmpty,
                  let expiry = tokens["expires_in"] as? Double, expiry > 0,
                  (tokens["token_type"] as? String)?.lowercased() == "bearer" else {
                throw GrammyError("Could not renew the ChatGPT connection. Sign in again.")
            }
            updated.accessToken = access
            updated.expiresAt = Date().addingTimeInterval(expiry)
            updated.refreshToken = tokens["refresh_token"] as? String ?? saved.refreshToken
            if let scope = tokens["scope"] as? String { updated.scopes = scope.components(separatedBy: " ") }
            guard updated.scopes.contains("chatgpt.tokens.use.direct") else {
                throw GrammyError("ChatGPT plan permission was removed. Sign in again or contact your workspace administrator.")
            }
            if let idToken = tokens["id_token"] as? String {
                let identity = try await verify(idToken, client: saved.clientID, nonce: nil)
                guard identity.subject == saved.subject else { throw GrammyError("Account verification failed. Sign in again.") }
                updated.idToken = idToken
                updated.email = identity.email ?? saved.email
            }
            try Task.checkCancellation()
            try save(updated)
            return access
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func loadModels() async {
        do {
            let token = try await accessToken()
            let requestingClient = credentials?.clientID
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let object = try await json(request)
            guard let values = object["models"] as? [[String: Any]] else { throw GrammyError("ChatGPT did not return its model catalog.") }
            let decoded = try JSONDecoder().decode([AvailableModel].self, from: JSONSerialization.data(withJSONObject: values))
            try Task.checkCancellation()
            guard isSignedIn, credentials?.clientID == requestingClient else { return }
            models = decoded.filter { $0.visibility == "list" }
            if !models.contains(where: { $0.slug == selectedModel }) { selectedModel = models.first?.slug ?? "" }
            if models.isEmpty { throw GrammyError("No models are available for this account. Check your workspace’s app permissions.") }
        } catch { message = error.localizedDescription }
    }

    private func makeCredentials(_ tokens: [String: Any], client: String, identity: VerifiedIdentity, idToken: String) throws -> Credentials {
        guard let access = tokens["access_token"] as? String, !access.isEmpty,
              let scope = tokens["scope"] as? String, scope.components(separatedBy: " ").contains("chatgpt.tokens.use.direct"),
              let expiry = tokens["expires_in"] as? Double, expiry > 0,
              (tokens["token_type"] as? String)?.lowercased() == "bearer" else {
            throw GrammyError("ChatGPT plan use was not authorized. Check the selected workspace’s permissions and sign in again.")
        }
        return Credentials(clientID: client, subject: identity.subject, email: identity.email,
            accessToken: access, refreshToken: tokens["refresh_token"] as? String,
            idToken: idToken, scopes: scope.components(separatedBy: " "), expiresAt: Date().addingTimeInterval(expiry))
    }
    private func save(_ saved: Credentials) throws {
        try CredentialStore.write(JSONEncoder().encode(saved))
        credentials = saved; email = saved.email ?? "ChatGPT account"; isSignedIn = true
    }
    private func verify(_ token: String, client: String, nonce: String?) async throws -> VerifiedIdentity {
        let (data, response) = try await session.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GrammyError("Could not verify ChatGPT sign-in. Try again.") }
        return try IDTokenVerifier.verify(token, jwks: data, clientID: client, nonce: nonce)
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthSupport.form(fields)
        return try await json(request)
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GrammyError("ChatGPT rejected the connection (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Sign in again or check your workspace’s app permissions.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GrammyError("ChatGPT returned an unexpected response.") }
        return object
    }
}

/// A short-lived HTTP callback bound exclusively to IPv4 loopback.
@MainActor
private final class LoopbackCallback {
    let expectedState: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<URL, Error>?
    private var received: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    init(expectedState: String) { self.expectedState = expectedState }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection, accumulated: Data()) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port {
                        self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                        self.ready = nil
                    }
                case .failed: self.finish(.failure(GrammyError("Could not start the local sign-in callback.")))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(GrammyError("Sign-in timed out. Please try again.")))
        }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }

    func wait() async throws -> URL {
        if let received { return try received.get() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func stop() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) {
        guard received == nil else { return }
        received = result
        ready?.resume(with: result); ready = nil
        waiting?.resume(with: result); waiting = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        if accumulated.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.received == nil else { connection.cancel(); return }
                let combined = accumulated + (data ?? Data())
                guard combined.count <= 16_384, error == nil else { connection.cancel(); return }
                guard let request = String(data: combined, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if done { connection.cancel() } else { self.receive(connection, accumulated: combined) }
                    return
                }
                let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                let target = first.count == 3 ? String(first[1]) : ""
                guard first.first == "GET", target.hasPrefix("/auth/callback?"),
                      let url = URL(string: "http://127.0.0.1" + target),
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      items.filter({ $0.name == "state" }).count == 1,
                      items.first(where: { $0.name == "state" })?.value == self.expectedState else {
                    self.respond(connection, status: "400 Bad Request", body: "Invalid callback. Return to Grammy and try again.")
                    return
                }
                self.respond(connection, status: "200 OK", body: "Return to Grammy to finish connecting. You can close this tab.")
                self.finish(.success(url))
            }
        }
    }
    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
