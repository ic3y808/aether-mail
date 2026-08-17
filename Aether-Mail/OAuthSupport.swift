import Foundation
import UIKit
import AuthenticationServices
import EmailKit

/// OAuth client IDs, read from a **gitignored** `OAuthClients.plist` bundled into
/// the app (so the public repo ships no personal identifiers). Absent plist =
/// OAuth simply disabled; the app still works with app-specific passwords.
enum OAuthClients {
    private static let dict: [String: String] = {
        guard let url = Bundle.main.url(forResource: "OAuthClients", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return d
    }()

    static var googleClientID: String { dict["google"] ?? "" }
    static var microsoftClientID: String { dict["microsoft"] ?? "" }
    static var microsoftTenant: String { dict["tenant"] ?? "common" }
    static var hasGoogle: Bool { !googleClientID.isEmpty }
    static var hasMicrosoft: Bool { !microsoftClientID.isEmpty }

    /// The EmailKit OAuth config (endpoints, scopes, redirect) for a provider,
    /// reusing the exact redirects the client IDs are registered for.
    static func config(for provider: MailProvider) -> OAuthConfig? {
        switch provider {
        case .gmail:   return hasGoogle ? ProviderCatalog.oauth(for: .gmail, clientID: googleClientID) : nil
        case .outlook: return hasMicrosoft ? ProviderCatalog.oauth(for: .outlook, clientID: microsoftClientID, tenant: microsoftTenant) : nil
        default:       return nil
        }
    }
}

/// Runs the interactive OAuth (PKCE) flow in an ASWebAuthenticationSession and
/// exchanges the code for tokens; also refreshes expired access tokens.
@MainActor
final class OAuthAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }

    func signIn(config: OAuthConfig) async throws -> OAuthTokens {
        let pair = OAuthPKCE.generatePair()
        guard let authURL = OAuthPKCE.authorizationURL(config: config, state: UUID().uuidString, challenge: pair.challenge) else {
            throw OAuthError.badConfig
        }
        let scheme = String(config.redirectURI.split(separator: ":").first ?? "")
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: err ?? OAuthError.cancelled) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() { cont.resume(throwing: OAuthError.cancelled) }
        }
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.noCode
        }
        return try await postToken(config.tokenEndpoint,
                                   body: OAuthPKCE.tokenExchangeBody(config: config, code: code, verifier: pair.verifier))
    }

    func refresh(config: OAuthConfig, refreshToken: String) async throws -> OAuthTokens {
        var tokens = try await postToken(config.tokenEndpoint,
                                         body: OAuthPKCE.refreshBody(config: config, refreshToken: refreshToken))
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }   // providers often omit it on refresh
        return tokens
    }

    private func postToken(_ url: URL, body: String) async throws -> OAuthTokens {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.tokenExchange(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    enum OAuthError: LocalizedError {
        case badConfig, cancelled, noCode, tokenExchange(String)
        var errorDescription: String? {
            switch self {
            case .badConfig:            return "OAuth isn't configured for this provider."
            case .cancelled:            return "Sign-in was cancelled."
            case .noCode:               return "Sign-in didn't return an authorization code."
            case .tokenExchange(let s): return "Couldn't complete sign-in. \(s)"
            }
        }
    }
}
