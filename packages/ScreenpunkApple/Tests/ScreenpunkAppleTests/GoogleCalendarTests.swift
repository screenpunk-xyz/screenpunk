import XCTest
import ScreenpunkCore
@testable import ScreenpunkApple

private final class CalendarCacheClock: PairingClock, @unchecked Sendable {
    var now = Date()
}

private actor CalendarTransport: HTTPTransport {
    var responses: [HTTPTransportResponse]
    var requests: [AuthorizedHTTPRequest] = []
    init(_ json: [String], statuses: [Int] = []) {
        responses = json.enumerated().map { .init(status: statuses.indices.contains($0.offset) ? statuses[$0.offset] : 200, body: Data($0.element.utf8)) }
    }
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
    func count() -> Int { requests.count }
    func captured() -> [AuthorizedHTTPRequest] { requests }
}


private actor SuspendedCalendarTransport: HTTPTransport {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<HTTPTransportResponse, Never>?
    func send(_ request: AuthorizedHTTPRequest) async throws -> HTTPTransportResponse {
        started = true; waiter?.resume(); waiter = nil
        return await withCheckedContinuation { response = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        response?.resume(returning: .init(status: 200, body: Data(#"{"access_token":"late-token","expires_in":3600,"token_type":"Bearer"}"#.utf8)))
        response = nil
    }
}

@MainActor
final class GoogleCalendarTests: XCTestCase {
    private let client = "123-example.apps.googleusercontent.com"
    private let range = ["timeMin": "2026-09-28T00:00:00Z", "timeMax": "2026-09-30T00:00:00Z"]
    private func fixture(transport: any HTTPTransport, expired: Bool = false, clock: any PairingClock = SystemClock()) throws -> (GoogleCalendarDeviceService, MemoryCredentialStore) {
        let store = MemoryCredentialStore()
        let calendars = [GoogleCalendarEntry(id: "family@example.com", summary: "Family")]
        let account = GoogleCalendarAccount(id: "person", email: "person@example.com", clientID: client, accessToken: "access-fixture", refreshToken: "refresh-fixture", expiresAt: expired ? .distantPast : Date().addingTimeInterval(3600), calendars: calendars)
        let selected = GoogleCalendarSelection(accountID: "person", calendarID: "family@example.com")
        let state = GoogleCalendarState(accounts: [account], selections: ["screen-one": [selected], "screen-two": [selected]])
        try store.put(JSONEncoder().encode(state), for: GoogleCalendarDeviceService.storageKey)
        return (GoogleCalendarDeviceService(store: store, transport: transport, clock: clock), store)
    }
    func testOAuthUsesPKCEAndValidatesExactCallback() throws {
        let oauth = try GoogleCalendarOAuth(clientID: client)
        let items = URLComponents(url: oauth.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(oauth.verifier.count, 43)
        XCTAssertNotEqual(oauth.verifier, oauth.state)
        let callback = URL(string: oauth.redirectURI + "?state=" + oauth.state + "&code=example")!
        XCTAssertEqual(try oauth.code(from: callback), "example")
        for suffix in ["?state=wrong&code=example", "?state=\(oauth.state)&code=a&code=b", "?state=\(oauth.state)&error=access_denied", "?state=\(oauth.state)&code=a#fragment"] {
            XCTAssertThrowsError(try oauth.code(from: URL(string: oauth.redirectURI + suffix)!))
        }
        XCTAssertThrowsError(try oauth.code(from: URL(string: "evil:/oauth2redirect?state=\(oauth.state)&code=a")!))
        XCTAssertThrowsError(try GoogleCalendarOAuth(clientID: "$(UNCONFIGURED)"))
    }
    func testFormEscapesReservedCharacters() {
        XCTAssertEqual(String(decoding: GoogleCalendarOAuth.form(["code": "a+b&c= d"]), as: UTF8.self), "code=a%2Bb%26c%3D%20d")
    }
    func testSelectionsAreIndependentAndRemovalClearsAllGrants() throws {
        let (service, store) = try fixture(transport: CalendarTransport([]))
        try service.select(dashboard: "screen-one", selection: .init(accountID: "person", calendarID: "family@example.com"), enabled: false)
        XCTAssertFalse(service.isReady(dashboard: "screen-one"))
        XCTAssertTrue(service.isReady(dashboard: "screen-two"))
        let restored = GoogleCalendarDeviceService(store: store, transport: CalendarTransport([]))
        XCTAssertTrue(restored.isReady(dashboard: "screen-two"))
        try service.disconnect(accountID: "person")
        XCTAssertTrue(try service.snapshot().accounts.isEmpty)
        XCTAssertFalse(service.isReady(dashboard: "screen-two"))
    }
    func testUnselectedScreensAndOversizedRangesCannotRead() async throws {
        let transport = CalendarTransport([])
        let (service, _) = try fixture(transport: transport)
        do { _ = try await service.events(dashboard: "other", parameters: range); XCTFail("Unselected screen read") } catch { XCTAssertEqual(error as? GoogleCalendarError, .permission) }
        do { _ = try await service.events(dashboard: "screen-one", parameters: ["timeMin": range["timeMin"]!, "timeMax": "2027-01-01T00:00:00Z"]); XCTFail("Unbounded range") } catch { XCTAssertEqual(error as? GoogleCalendarError, .invalidRequest) }
        let count = await transport.count(); XCTAssertEqual(count, 0)
    }
    func testPaginationAllDayAndDisplayFieldFiltering() async throws {
        let transport = CalendarTransport([
            #"{"items":[{"id":"first","summary":"Holiday","start":{"date":"2026-09-28"},"end":{"date":"2026-09-29"},"attendees":[{"email":"private@example.com"}]}],"nextPageToken":"page two"}"#,
            #"{"items":[{"id":"cancelled","status":"cancelled"},{"id":"second","start":{"dateTime":"2026-09-28T14:00:00-04:00","timeZone":"America/Detroit"},"end":{"dateTime":"2026-09-28T15:00:00-04:00"}}]}"#
        ])
        let (service, _) = try fixture(transport: transport)
        let result = try await service.events(dashboard: "screen-one", parameters: range)
        let events = result.value["events"] as! [[String: Any]]
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual((events[0]["start"] as? [String: String])?["date"], "2026-09-28")
        XCTAssertNil(events[0]["attendees"])
        XCTAssertEqual(events[1]["summary"] as? String, "Busy")
        XCTAssertFalse(result.stale)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url.absoluteString.contains("family%40example%2Ecom"))
        XCTAssertTrue(requests[1].url.absoluteString.contains("pageToken=page%20two"))
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer access-fixture")
        _ = try await service.events(dashboard: "screen-one", parameters: range)
        let count = await transport.count(); XCTAssertEqual(count, 2)
    }
    func testRefreshPreservesRefreshTokenAndPersists() async throws {
        let transport = CalendarTransport([
            #"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#,
            #"{"items":[]}"#
        ])
        let (service, _) = try fixture(transport: transport, expired: true)
        _ = try await service.events(dashboard: "screen-one", parameters: range)
        let account = try XCTUnwrap(service.snapshot().accounts.first)
        XCTAssertEqual(account.accessToken, "new-access")
        XCTAssertEqual(account.refreshToken, "refresh-fixture")
        let requests = await transport.captured()
        XCTAssertEqual(requests[0].url.host, "oauth2.googleapis.com")
        XCTAssertFalse(String(decoding: requests[0].body!, as: UTF8.self).contains("client_secret"))
    }
    func testInvalidGrantRequiresReconnect() async throws {
        let transport = CalendarTransport([#"{"error":"invalid_grant"}"#], statuses: [400])
        let (service, _) = try fixture(transport: transport, expired: true)
        do { _ = try await service.events(dashboard: "screen-one", parameters: range); XCTFail("Revoked grant accepted") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .reconnect) }
    }
    func testCalendarRefreshRemovesLostCalendarFromSelections() async throws {
        let (service, _) = try fixture(transport: CalendarTransport([#"{"items":[{"id":"different","summary":"Other"}]}"#]))
        try await service.reloadCalendars(accountID: "person")
        XCTAssertFalse(service.isReady(dashboard: "screen-one"))
        XCTAssertFalse(service.isReady(dashboard: "screen-two"))
    }
    func testEraseRemovesPersistentData() throws {
        let (service, store) = try fixture(transport: CalendarTransport([]))
        let before = service.generation
        try service.erase()
        XCTAssertNotEqual(before, service.generation)
        XCTAssertNil(try store.secret(for: GoogleCalendarDeviceService.storageKey))
    }
    func testPartialScopesAreRejectedBeforeSavingAccount() async throws {
        let transport = CalendarTransport([#"{"access_token":"new","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer","scope":"openid email"}"#])
        let store = MemoryCredentialStore()
        let service = GoogleCalendarDeviceService(store: store, transport: transport)
        do { try await service.connect(oauth: GoogleCalendarOAuth(clientID: client), code: "example", expected: service.generation); XCTFail("Partial scopes accepted") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .permission) }
        XCTAssertNil(try store.secret(for: GoogleCalendarDeviceService.storageKey))
    }
    func testUnlinkDuringRefreshCannotRestoreCredentials() async throws {
        let transport = SuspendedCalendarTransport()
        let (service, store) = try fixture(transport: transport, expired: true)
        let read = Task { try await service.events(dashboard: "screen-one", parameters: range) }
        await transport.waitUntilStarted()
        try service.erase()
        await transport.release()
        do { _ = try await read.value; XCTFail("Read survived unlink") } catch { }
        XCTAssertNil(try store.secret(for: GoogleCalendarDeviceService.storageKey))
    }
    func testRateLimitStopsImmediateRetries() async throws {
        let transport = CalendarTransport([#"{"error":{"code":429}}"#], statuses: [429])
        let (service, _) = try fixture(transport: transport)
        for _ in 0..<2 {
            do { _ = try await service.events(dashboard: "screen-one", parameters: range); XCTFail("Rate limit ignored") }
            catch { XCTAssertEqual(error as? GoogleCalendarError, .rateLimited) }
        }
        let count = await transport.count(); XCTAssertEqual(count, 1)
    }

    func testProfilesExposeOnlySelectedAccountsAndNoCredentials() async throws {
        let (service, store) = try fixture(transport: CalendarTransport([#"{"items":[]}"#]))
        var state = try service.snapshot()
        state.accounts[0].displayName = "Family member"
        state.accounts[0].pictureURL = "https://lh3.googleusercontent.com/example"
        var other = state.accounts[0]; other.id = "unselected"; other.displayName = "Private account"
        state.accounts.append(other)
        try store.put(JSONEncoder().encode(state), for: GoogleCalendarDeviceService.storageKey)
        let result = try await service.events(dashboard: "screen-one", parameters: range)
        let profiles = try XCTUnwrap(result.value["accounts"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["displayName"] as? String, "Family member")
        XCTAssertEqual(profiles[0]["pictureURL"] as? String, "https://lh3.googleusercontent.com/example")
        XCTAssertEqual(Set(profiles[0].keys), Set(["accountID", "displayName", "pictureURL"]))
        XCTAssertNil(GoogleCalendarDeviceService.profilePicture("http://example.com/avatar"))
        XCTAssertNil(GoogleCalendarDeviceService.profilePicture("https://user:password@example.com/avatar"))
    }
    func testLegacyProfileFieldsAreOptional() async throws {
        let (service, store) = try fixture(transport: CalendarTransport([#"{"items":[]}"#]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.secret(for: GoogleCalendarDeviceService.storageKey)!) as? [String: Any])
        var accounts = object["accounts"] as! [[String: Any]]
        accounts[0].removeValue(forKey: "displayName"); accounts[0].removeValue(forKey: "pictureURL")
        object["accounts"] = accounts
        try store.put(JSONSerialization.data(withJSONObject: object), for: GoogleCalendarDeviceService.storageKey)
        let result = try await service.events(dashboard: "screen-one", parameters: range)
        let profiles = try XCTUnwrap(result.value["accounts"] as? [[String: Any]])
        XCTAssertEqual(profiles[0]["displayName"] as? String, "person@example.com")
        XCTAssertNil(profiles[0]["pictureURL"])
        XCTAssertTrue(GoogleCalendarOAuth.scopes.contains("profile"))
    }

    func testSelectedCalendarInventoryIncludesEmptyCalendarsAcrossAccounts() async throws {
        // Seven selected calendars, only five with events; two accounts share a calendar ID.
        let transport = CalendarTransport((0..<7).map { $0 < 5 ? #"{"items":[{"id":"event"}]}"# : #"{"items":[]}"# })
        let (service, store) = try fixture(transport: transport)
        var state = try service.snapshot()
        state.accounts[0].calendars = (0..<6).map { .init(id: "calendar-\($0)", summary: "Calendar \($0)") }
        var other = state.accounts[0]; other.id = "second-account"
        other.calendars = [.init(id: "calendar-0", summary: "Shared title"), .init(id: "private", summary: "Not selected")]
        state.accounts.append(other)
        state.selections["screen-one"] = (0..<6).map { .init(accountID: "person", calendarID: "calendar-\($0)") } + [.init(accountID: other.id, calendarID: "calendar-0")]
        state.selections["other-screen"] = [.init(accountID: other.id, calendarID: "private")]
        try store.put(JSONEncoder().encode(state), for: GoogleCalendarDeviceService.storageKey)
        for _ in 0..<2 {
            let result = try await service.events(dashboard: "screen-one", parameters: range)
            let calendars = try XCTUnwrap(result.value["calendars"] as? [[String: String]])
            XCTAssertEqual(calendars.count, 7)
            XCTAssertEqual((result.value["events"] as? [[String: Any]])?.count, 5)
            XCTAssertEqual(calendars.last, ["accountID": "second-account", "calendarID": "calendar-0", "displayName": "Shared title"])
            XCTAssertEqual(calendars[5]["displayName"], "Calendar 5")
            XCTAssertTrue(calendars.allSatisfy { Set($0.keys) == Set(["accountID", "calendarID", "displayName"]) })
            XCTAssertFalse(calendars.contains { $0["calendarID"] == "private" })
        }
        let count = await transport.count(); XCTAssertEqual(count, 7, "Fresh cache must not refetch calendars or events")
    }

    func testCalendarInventorySurvivesTransientStaleFallbackButNotSelectionRemoval() async throws {
        let clock = CalendarCacheClock()
        let (service, _) = try fixture(transport: CalendarTransport([#"{"items":[]}"#]), clock: clock)
        let fresh = try await service.events(dashboard: "screen-one", parameters: range)
        clock.now.addTimeInterval(61)
        let stale = try await service.events(dashboard: "screen-one", parameters: range)
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.value["calendars"] as? [[String: String]], fresh.value["calendars"] as? [[String: String]])
        XCTAssertEqual(stale.value["fetchedAt"] as? String, fresh.value["fetchedAt"] as? String)
        try service.select(dashboard: "screen-one", selection: .init(accountID: "person", calendarID: "family@example.com"), enabled: false)
        do { _ = try await service.events(dashboard: "screen-one", parameters: range); XCTFail("Removed selection returned cached metadata") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .permission) }
    }

    func testCalendarInventoryDoesNotTurnPermissionFailureIntoCachedSuccess() async throws {
        let clock = CalendarCacheClock()
        let (service, _) = try fixture(transport: CalendarTransport([#"{"items":[]}"#, #"{"error":{"code":403}}"#], statuses: [200, 403]), clock: clock)
        _ = try await service.events(dashboard: "screen-one", parameters: range)
        clock.now.addTimeInterval(61)
        do { _ = try await service.events(dashboard: "screen-one", parameters: range); XCTFail("Permission failure returned metadata") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .permission) }
        do { _ = try await service.events(dashboard: "screen-one", parameters: range); XCTFail("Permission failure retained stale cache") }
        catch { XCTAssertTrue(error is URLError) }
    }

}
