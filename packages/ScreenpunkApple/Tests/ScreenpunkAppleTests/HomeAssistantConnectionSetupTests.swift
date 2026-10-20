import XCTest
@testable import ScreenpunkApple

final class HomeAssistantConnectionSetupTests: XCTestCase {
    func testSchemeInferenceAndExplicitHTTPConsent() throws {
        XCTAssertEqual(try HomeAssistantConnectionSetup.origins(" homeassistant.local:8123 ", allowHTTP: false), ["https://homeassistant.local:8123"])
        XCTAssertEqual(try HomeAssistantConnectionSetup.origins("10.0.0.224:8123", allowHTTP: true), ["https://10.0.0.224:8123", "http://10.0.0.224:8123"])
        XCTAssertEqual(try HomeAssistantConnectionSetup.origins("http://home.local:8123/lovelace/main", allowHTTP: true), ["http://home.local:8123"])
        XCTAssertEqual(try HomeAssistantConnectionSetup.origins("https://home.example", allowHTTP: true), ["https://home.example"])
        XCTAssertThrowsError(try HomeAssistantConnectionSetup.origins("http://home.local", allowHTTP: false))
        for address in ["", "ftp://home.local", "https://user:secret@home.local", "https://home.local?token=secret", "https://home.local#secret"] {
            XCTAssertThrowsError(try HomeAssistantConnectionSetup.origins(address, allowHTTP: true))
        }
    }
    func testChecksTokenAndOnlyFallsBackToConsentedHTTPAfterTransportFailure() async throws {
        var schemes: [String] = []
        let resolved = try await HomeAssistantConnectionSetup.verify(address: "home.local:8123", token: "test-token", allowHTTP: true) { request in
            schemes.append(request.url!.scheme!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            if request.url!.scheme == "https" { throw URLError(.secureConnectionFailed) }
            return (Data("{\"message\":\"API running.\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(resolved, "http://home.local:8123")
        XCTAssertEqual(schemes, ["https", "http"])
        var calls = 0
        do {
            _ = try await HomeAssistantConnectionSetup.verify(address: "home.local", token: "test-token", allowHTTP: true) { request in
                calls += 1
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("Rejected token must not be saved")
        } catch { XCTAssertEqual(calls, 1) }
        do {
            _ = try await HomeAssistantConnectionSetup.verify(address: "home.local", token: "test-token", allowHTTP: true) { _ in throw URLError(.serverCertificateUntrusted) }
            XCTFail("An invalid HTTPS certificate must not trigger downgrade")
        } catch { }
    }
    func testQRTokenIsOnlyAcceptedAsRawJWTAndNeverAsURL() throws {
        XCTAssertEqual(try HomeAssistantConnectionSetup.scannedToken(" eyJhbGci.eyJpc3Mi.signature_123- \n"), "eyJhbGci.eyJpc3Mi.signature_123-")
        for code in ["https://example.com/?token=ey.a.b", "javascript:alert(1)", "not a token", "a..c", "a.b.c.d", String(repeating: "a", count: 8200) + ".b.c"] {
            XCTAssertThrowsError(try HomeAssistantConnectionSetup.scannedToken(code))
        }
    }
}
