import CryptoKit
import Foundation

public struct OAuthRegisteredClient: Sendable {
    public let clientID: String
    public let clientName: String
    public let redirectURIs: [String]
    public let issuedAt: Int
}

private struct OAuthAuthorizationCode: Sendable {
    let code: String
    let clientID: String
    let redirectURI: String
    let codeChallenge: String
    let resource: String
    let expiresAt: Date
}

private struct OAuthAccessToken: Sendable {
    let token: String
    let resource: String
    let expiresAt: Date
}

public actor OAuthTokenStore {
    private var clients: [String: OAuthRegisteredClient] = [:]
    private var authorizationCodes: [String: OAuthAuthorizationCode] = [:]
    private var accessTokens: [String: OAuthAccessToken] = [:]

    public init() {}

    public func registerClient(clientName: String, redirectURIs: [String], now: Date = Date()) -> OAuthRegisteredClient {
        let client = OAuthRegisteredClient(
            clientID: ConfigManager.generateSecureToken(),
            clientName: clientName,
            redirectURIs: redirectURIs,
            issuedAt: Int(now.timeIntervalSince1970)
        )
        clients[client.clientID] = client
        return client
    }

    public func client(id: String) -> OAuthRegisteredClient? {
        clients[id]
    }

    public func issueAuthorizationCode(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        resource: String,
        now: Date = Date()
    ) -> String? {
        cleanup(now: now)
        guard let client = clients[clientID], client.redirectURIs.contains(redirectURI) else {
            return nil
        }

        let code = ConfigManager.generateSecureToken()
        authorizationCodes[code] = OAuthAuthorizationCode(
            code: code,
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            resource: resource,
            expiresAt: now.addingTimeInterval(300)
        )
        return code
    }

    public func redeemAuthorizationCode(
        code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String,
        now: Date = Date()
    ) -> String? {
        cleanup(now: now)
        guard let pending = authorizationCodes.removeValue(forKey: code),
              pending.clientID == clientID,
              pending.redirectURI == redirectURI,
              OAuthSupport.constantTimeEquals(OAuthSupport.pkceS256Challenge(for: codeVerifier), pending.codeChallenge) else {
            return nil
        }

        let token = ConfigManager.generateSecureToken()
        accessTokens[token] = OAuthAccessToken(
            token: token,
            resource: pending.resource,
            expiresAt: now.addingTimeInterval(12 * 60 * 60)
        )
        return token
    }

    public func isValidAccessToken(_ token: String, resource: String, now: Date = Date()) -> Bool {
        cleanup(now: now)
        guard let accessToken = accessTokens[token] else {
            return false
        }
        guard accessToken.expiresAt > now else {
            return false
        }
        return OAuthSupport.constantTimeEquals(accessToken.resource, resource)
    }

    private func cleanup(now: Date) {
        authorizationCodes = authorizationCodes.filter { $0.value.expiresAt > now }
        accessTokens = accessTokens.filter { $0.value.expiresAt > now }
    }
}

public enum OAuthSupport {
    public static func pkceS256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    public static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func parseFormURLEncoded(_ data: Data) -> [String: String] {
        guard let raw = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecodedFormValue(String(parts.first ?? ""))
            let value = parts.count > 1 ? percentDecodedFormValue(String(parts[1])) : ""
            values[key] = value
        }
        return values
    }

    public static func percentDecodedFormValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? value
    }

    public static func queryDictionary(_ queryItems: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in queryItems {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    public static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func isAllowedRedirectURI(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return false
        }

        if scheme == "https" {
            return true
        }

        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        return false
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        SSEServer.constantTimeEquals(lhs, rhs)
    }
}
