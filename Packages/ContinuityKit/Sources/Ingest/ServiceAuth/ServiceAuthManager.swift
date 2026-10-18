import AuthenticationServices
import ContinuityCore
import CryptoKit
import Foundation
import UIKit
import os

private let authLog = Logger(subsystem: "com.continuity.app", category: "auth")

/// Connected streaming accounts: runs the OAuth sign-in (Authorization Code + PKCE through
/// `ASWebAuthenticationSession`), keeps tokens in the Keychain, and hands out a fresh bearer token
/// on demand — refreshing behind the scenes when one is about to expire.
///
/// Main-actor + `@Observable` so the import hub's "Connected / Connect" rows update live. The
/// pure flow mechanics live in `ContinuityCore.OAuthFlow`; this type adds the browser session,
/// networking, and storage.
@MainActor
@Observable
public final class ServiceAuthManager {
    public let configuration: ServiceAuthConfiguration
    private let store: CredentialStore
    private let session: URLSession

    /// Services with stored credentials. Observed by the UI.
    public private(set) var connectedServices: Set<MusicService> = []
    /// Services with a sign-in browser session currently up (drives the row spinner).
    public private(set) var signingIn: Set<MusicService> = []

    private var credentials: [MusicService: ServiceCredentials] = [:]
    /// In-flight refreshes, so concurrent API calls share one token request.
    private var refreshes: [MusicService: Task<String, Error>] = [:]
    /// The live browser session must be retained for its whole lifetime.
    private var activeSession: ASWebAuthenticationSession?
    private let presenter = WebAuthPresenter()

    public init(
        configuration: ServiceAuthConfiguration = .fromBundle(),
        store: CredentialStore = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.store = store
        self.session = session
        for service in MusicService.allCases {
            if let data = store.load(account: service.rawValue),
               let stored = try? JSONDecoder().decode(ServiceCredentials.self, from: data) {
                credentials[service] = stored
                connectedServices.insert(service)
            }
        }
    }

    /// Preview/test double: nothing configured, nothing stored.
    public static func inMemory(configuration: ServiceAuthConfiguration = ServiceAuthConfiguration()) -> ServiceAuthManager {
        ServiceAuthManager(configuration: configuration, store: InMemoryCredentialStore())
    }

    public func isConfigured(_ service: MusicService) -> Bool { configuration.isConfigured(service) }
    public func isConnected(_ service: MusicService) -> Bool { connectedServices.contains(service) }

    // MARK: - Sign in / out

    /// Runs the whole sign-in: browser consent → code → tokens → Keychain. Throws
    /// `IngestError.notConfigured` when the build has no client id, `.authorizationFailed` when
    /// the user cancels or the provider refuses, `.network` for token-endpoint failures.
    public func signIn(_ service: MusicService) async throws {
        let provider = configuration.provider(for: service)
        guard provider.isConfigured, let scheme = provider.callbackScheme else {
            throw IngestError.notConfigured(service)
        }
        guard !signingIn.contains(service) else { return }
        signingIn.insert(service)
        defer { signingIn.remove(service) }

        let verifier = OAuthFlow.makeVerifier()
        let state = OAuthFlow.makeVerifier(length: 32)
        let challenge = OAuthFlow.challenge(verifier: verifier) { Data(SHA256.hash(data: $0)) }
        guard let authURL = OAuthFlow.authorizationURL(config: provider, state: state, challenge: challenge) else {
            throw IngestError.invalidURL
        }

        let callback = try await presentConsent(url: authURL, callbackScheme: scheme)
        let code: String
        do {
            code = try OAuthFlow.parseCallback(callback, expectedState: state)
        } catch let error as OAuthFlow.CallbackError {
            authLog.error("\(service.rawValue, privacy: .public) callback rejected: \(String(describing: error), privacy: .public)")
            throw IngestError.authorizationFailed(String(describing: error))
        }

        let response = try await postToken(
            provider: provider,
            body: OAuthFlow.tokenRequestBody(config: provider, code: code, verifier: verifier)
        )
        persist(ServiceCredentials(response), for: service)
    }

    /// Forgets the account locally. Provider-side consent is left alone (revoking needs
    /// another API call per provider and the user can do it from their account page).
    public func signOut(_ service: MusicService) {
        refreshes[service]?.cancel()
        refreshes[service] = nil
        credentials[service] = nil
        connectedServices.remove(service)
        store.delete(account: service.rawValue)
    }

    // MARK: - Tokens

    /// A bearer token that is valid for at least another minute, refreshing if needed. Throws
    /// `IngestError.notSignedIn` when the service isn't connected or the refresh was rejected
    /// (the account is disconnected in that case — the user has to sign in again).
    func accessToken(for service: MusicService, forceRefresh: Bool = false) async throws -> String {
        guard let current = credentials[service] else { throw IngestError.notSignedIn(service) }
        if !forceRefresh, !current.isExpiring() { return current.accessToken }

        if let inFlight = refreshes[service] { return try await inFlight.value }
        guard let refreshToken = current.refreshToken else {
            // No way to renew: the stored token is all we have. Hand it over if it's merely
            // "about to" expire; a hard 401 then disconnects via `invalidate`.
            if !forceRefresh, current.expiresAt.map({ $0 > Date() }) ?? true { return current.accessToken }
            invalidate(service)
            throw IngestError.notSignedIn(service)
        }

        let provider = configuration.provider(for: service)
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw IngestError.notSignedIn(service) }
            do {
                let response = try await self.postToken(
                    provider: provider,
                    body: OAuthFlow.refreshRequestBody(config: provider, refreshToken: refreshToken)
                )
                let refreshed = current.refreshed(with: response)
                self.persist(refreshed, for: service)
                return refreshed.accessToken
            } catch let error as IngestError where error.isRetryable {
                throw error   // transient: keep the account, let the caller retry later
            } catch {
                authLog.error("\(service.rawValue, privacy: .public) refresh rejected — disconnecting: \(String(describing: error), privacy: .public)")
                self.invalidate(service)
                throw IngestError.notSignedIn(service)
            }
        }
        refreshes[service] = task
        defer { refreshes[service] = nil }
        return try await task.value
    }

    /// Drops credentials the API has definitively rejected.
    func invalidate(_ service: MusicService) {
        signOut(service)
    }

    // MARK: - Private

    private func persist(_ creds: ServiceCredentials, for service: MusicService) {
        credentials[service] = creds
        connectedServices.insert(service)
        if let data = try? JSONEncoder().encode(creds) {
            store.save(data, account: service.rawValue)
        }
    }

    /// Shows the provider's consent page and returns the redirect URL it ends on.
    private func presentConsent(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let webSession = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callback, error in
                Task { @MainActor in self?.activeSession = nil }
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: IngestError.authorizationFailed("cancelled"))
                } else {
                    continuation.resume(throwing: IngestError.authorizationFailed(String(describing: error)))
                }
            }
            webSession.presentationContextProvider = presenter
            // Shared cookies: an existing Spotify/Google login in Safari skips the password step.
            webSession.prefersEphemeralWebBrowserSession = false
            activeSession = webSession
            if !webSession.start() {
                activeSession = nil
                continuation.resume(throwing: IngestError.authorizationFailed("could not present sign-in"))
            }
        }
    }

    /// POSTs a form body to the token endpoint and parses the reply.
    private func postToken(provider: OAuthProviderConfig, body: Data) async throws -> OAuthFlow.TokenResponse {
        var request = URLRequest(url: provider.tokenEndpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IngestError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 429: throw IngestError.rateLimited
            case 500..<600: throw IngestError.network("token endpoint HTTP \(http.statusCode)")
            default:
                let detail = String(data: data, encoding: .utf8) ?? ""
                authLog.error("\(provider.service.rawValue, privacy: .public) token HTTP \(http.statusCode): \(detail, privacy: .public)")
                throw IngestError.authorizationFailed("token endpoint HTTP \(http.statusCode)")
            }
        }
        guard let parsed = OAuthFlow.parseTokenResponse(data) else {
            throw IngestError.authorizationFailed("token endpoint returned no access token")
        }
        return parsed
    }
}

/// Anchors the consent sheet on the app's key window.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // AuthenticationServices calls this on the main thread; the SDK's isolation annotation
        // varies by release, so assert rather than assume.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
            return window ?? ASPresentationAnchor()
        }
    }
}
