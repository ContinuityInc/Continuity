import XCTest
@testable import ContinuityCore

final class OAuthFlowTests: XCTestCase {

    private let spotify = OAuthProviders.spotify(clientID: "cid123", redirectURI: "continuity://auth/spotify")

    func testVerifierIsRFC7636Shaped() {
        let verifier = OAuthFlow.makeVerifier()
        XCTAssertEqual(verifier.count, 64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.allSatisfy(allowed.contains))
        XCTAssertNotEqual(verifier, OAuthFlow.makeVerifier())
    }

    func testChallengeIsBase64URLOfInjectedHash() {
        // Identity "hash": proves the padding/alphabet transform without needing SHA-256 here.
        let challenge = OAuthFlow.challenge(verifier: "abc?>", sha256: { $0 })
        XCTAssertEqual(challenge, "YWJjPz4")                          // "YWJjPz4=" minus padding
        XCTAssertEqual(OAuthFlow.base64URL(Data([0xfb, 0xff])), "-_8")   // + → -, / → _
    }

    func testAuthorizationURL() throws {
        let url = try XCTUnwrap(OAuthFlow.authorizationURL(config: spotify, state: "st", challenge: "ch"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "accounts.spotify.com")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "cid123")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "continuity://auth/spotify")
        XCTAssertEqual(items["code_challenge"], "ch")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "st")
        XCTAssertEqual(items["scope"], "playlist-read-private playlist-read-collaborative user-library-read")

        let google = OAuthProviders.google(clientID: "1234-abc.apps.googleusercontent.com")
        XCTAssertEqual(google.redirectURI, "com.googleusercontent.apps.1234-abc:/oauth2redirect")
        XCTAssertEqual(google.callbackScheme, "com.googleusercontent.apps.1234-abc")
        let googleURL = try XCTUnwrap(OAuthFlow.authorizationURL(config: google, state: "s", challenge: "c"))
        XCTAssertTrue(googleURL.absoluteString.contains("access_type=offline"))
        XCTAssertFalse(OAuthProviders.google(clientID: "").isConfigured)
    }

    func testCallbackParsing() throws {
        let ok = URL(string: "continuity://auth/spotify?code=AUTHCODE&state=st")!
        XCTAssertEqual(try OAuthFlow.parseCallback(ok, expectedState: "st"), "AUTHCODE")

        let fragment = URL(string: "continuity://auth/spotify#code=FRAG&state=st")!
        XCTAssertEqual(try OAuthFlow.parseCallback(fragment, expectedState: "st"), "FRAG")

        XCTAssertThrowsError(try OAuthFlow.parseCallback(ok, expectedState: "other")) {
            XCTAssertEqual($0 as? OAuthFlow.CallbackError, .stateMismatch)
        }
        let denied = URL(string: "continuity://auth/spotify?error=access_denied&state=st")!
        XCTAssertThrowsError(try OAuthFlow.parseCallback(denied, expectedState: "st")) {
            XCTAssertEqual($0 as? OAuthFlow.CallbackError, .providerError("access_denied"))
        }
        let noCode = URL(string: "continuity://auth/spotify?state=st")!
        XCTAssertThrowsError(try OAuthFlow.parseCallback(noCode, expectedState: "st")) {
            XCTAssertEqual($0 as? OAuthFlow.CallbackError, .missingCode)
        }
    }

    func testTokenRequestBodies() {
        let body = String(decoding: OAuthFlow.tokenRequestBody(config: spotify, code: "c o/de", verifier: "v"), as: UTF8.self)
        XCTAssertEqual(
            body,
            "client_id=cid123&code=c+o%2Fde&code_verifier=v&grant_type=authorization_code&redirect_uri=continuity%3A%2F%2Fauth%2Fspotify"
        )
        XCTAssertFalse(body.contains("client_secret"))

        let soundcloud = OAuthProviders.soundcloud(clientID: "sc", clientSecret: "shh", redirectURI: "continuity://auth/soundcloud")
        let refresh = String(decoding: OAuthFlow.refreshRequestBody(config: soundcloud, refreshToken: "r"), as: UTF8.self)
        XCTAssertEqual(refresh, "client_id=sc&client_secret=shh&grant_type=refresh_token&refresh_token=r")
    }

    func testTokenResponseAndCredentialsLifecycle() throws {
        let json = #"{"access_token":"A","token_type":"Bearer","expires_in":3600,"refresh_token":"R","scope":"x y"}"#
        let response = try XCTUnwrap(OAuthFlow.parseTokenResponse(Data(json.utf8)))
        XCTAssertEqual(response, OAuthFlow.TokenResponse(accessToken: "A", refreshToken: "R", expiresIn: 3600, scope: "x y"))
        XCTAssertNil(OAuthFlow.parseTokenResponse(Data(#"{"error":"invalid_grant"}"#.utf8)))

        let now = Date(timeIntervalSince1970: 1_000_000)
        let credentials = ServiceCredentials(response, now: now)
        XCTAssertEqual(credentials.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(credentials.isExpiring(within: 60, now: now))
        XCTAssertTrue(credentials.isExpiring(within: 60, now: now.addingTimeInterval(3550)))

        // A refresh that omits the refresh token keeps the old one (Google's behaviour).
        let refreshed = credentials.refreshed(with: OAuthFlow.TokenResponse(accessToken: "B", expiresIn: 100), now: now)
        XCTAssertEqual(refreshed.accessToken, "B")
        XCTAssertEqual(refreshed.refreshToken, "R")
        XCTAssertEqual(refreshed.scope, "x y")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(100))

        // No expiry → trusted until the API says otherwise.
        XCTAssertFalse(ServiceCredentials(accessToken: "Z").isExpiring())
    }
}
