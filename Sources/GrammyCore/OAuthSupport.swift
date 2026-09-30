import Foundation
import CryptoKit
import Security

public enum OAuthSupport {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GrammyError("Could not prepare secure sign-in.")
        }
        return base64url(Data(bytes))
    }
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ string: String) -> Data? {
        let normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
    public static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    public static func callback(_ url: URL, state: String, clientID: String?) throws -> (code: String, client: String) {
        guard url.path == "/auth/callback", let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw GrammyError("Invalid sign-in callback.")
        }
        func single(_ name: String) throws -> String? {
            let values = query.filter { $0.name == name }
            guard values.count <= 1 else { throw GrammyError("Invalid sign-in callback.") }
            return values.first?.value
        }
        guard try single("state") == state else { throw GrammyError("Sign-in verification failed. Please try again.") }
        if try single("error") != nil { throw GrammyError("Sign-in was declined. Your workspace may not allow ChatGPT plan usage by this app.") }
        let returnedClient = try single("client_id")
        if let clientID, let returnedClient, clientID != returnedClient {
            throw GrammyError("Sign-in returned a different app registration. Please try again.")
        }
        guard let code = try single("code"), !code.isEmpty,
              let client = returnedClient ?? clientID, !client.isEmpty, client != "dynamic_agent_client" else {
            throw GrammyError("ChatGPT did not complete the app registration.")
        }
        return (code, client)
    }
}

public struct VerifiedIdentity {
    public let subject: String
    public let email: String?
}

public enum IDTokenVerifier {
    /// Only accepts RS256 keys from the caller's trusted OpenAI JWKS endpoint.
    public static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> VerifiedIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = OAuthSupport.decode(parts[0]),
              let claimsData = OAuthSupport.decode(parts[1]), let signature = OAuthSupport.decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = set["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256",
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = OAuthSupport.decode(n), let exponent = OAuthSupport.decode(e) else {
            throw GrammyError("Could not verify ChatGPT’s sign-in signature.")
        }
        let der = tagged(0x30, integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil) else {
            throw GrammyError("ChatGPT’s sign-in signature was invalid.")
        }
        guard let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5 else {
            throw GrammyError("ChatGPT’s sign-in identity is invalid or expired.")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              audiences.count <= 1 || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce else {
            throw GrammyError("ChatGPT’s sign-in identity does not match this request.")
        }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 5 {
            throw GrammyError("ChatGPT’s sign-in identity is not valid yet.")
        }
        return VerifiedIdentity(subject: subject, email: claims["email"] as? String)
    }

    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first! >= 128 { value.insert(0, at: 0) }
        return tagged(0x02, value)
    }
    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        var size = value.count
        var length: [UInt8] = []
        if size < 128 { length = [UInt8(size)] }
        else {
            while size > 0 { length.insert(UInt8(size & 255), at: 0); size >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + value
    }
}
