import XCTest
@testable import ScreenpunkCore

final class PublicReadTests: XCTestCase {
    func declaration() -> PublicReadDeclaration {
        .init(origin: "https://data.example.org", operations: [
            .init(name: "frame", path: "/frames/{time}/{point}.png", response: "raster", parameters: [
                "time": .init(location: "path", minimum: 0, maximum: 2000),
                "point": .init(location: "path", values: ["12.5,-40.5"]),
                "bbox": .init(location: "query", values: ["-10.25,20.5,30.25,40.5"]),
                "fields": .init(location: "query", values: ["first,second"])
            ])])
    }
    var params: [String: String] { ["time": "1000", "point": "12.5,-40.5", "bbox": "-10.25,20.5,30.25,40.5", "fields": "first,second"] }
    func testFixedQueriesAndBoundedCoordinatesResolveThroughSharedPolicy() throws {
        let d = declaration(); try d.validate(alias: "tiles")
        let (grant, query) = try d.grant(alias: "tiles", operation: d.operations[0], parameters: params)
        let result = try ConnectionPolicy.authorize(grant: grant, operationName: "frame", parameters: query,
            resolvedAddresses: ["203.0.113.10"], binding: .init(authRef: "public-no-auth", placement: .none))
        XCTAssertEqual(result.url.path, "/frames/1000/12.5,-40.5.png")
        let url = try ConnectionPolicy.mergeQueryParameters(url: result.url, parameters: result.queryParameters)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "fields" })?.value, "first,second")
    }
    func testDestinationAndParameterRejections() throws {
        for origin in ["http://data.example.org", "https://localhost", "https://127.0.0.1", "https://10.0.0.1", "https://user@data.example.org", "https://data.example.org/other", "https://data.example.org:8443", "https://data.example.org#fragment"] {
            var d = declaration(); d.origin = origin; XCTAssertThrowsError(try d.validate(alias: "tiles"), origin)
        }
        for value in ["2001", "-1", "01", "1.0", "../x", "%2f", "https://evil.example"] {
            var p = params; p["time"] = value
            XCTAssertThrowsError(try declaration().operations[0].resolve(p), value)
        }
        for key in ["url", "headers", "token", "unknown"] {
            var p = params; p[key] = "x"; XCTAssertThrowsError(try declaration().operations[0].resolve(p))
        }
        for path in ["//evil.example/a", "/a/../b", "/a%2fb", "/a?url=x", "/a#b", "/{unknown}"] {
            var d = declaration(); d.operations[0].path = path; XCTAssertThrowsError(try d.validate(alias: "tiles"))
        }
        let d = declaration(); let (grant, query) = try d.grant(alias: "tiles", operation: d.operations[0], parameters: params)
        for ip in ["127.0.0.1", "169.254.169.254", "192.168.1.1", "::1", "fd00::1", "::ffff:7f00:1", "::ffff:a9fe:a9fe", "0:0:0:0:0:0:0:1", "::", "ff02::1"] {
            XCTAssertThrowsError(try ConnectionPolicy.authorize(grant: grant, operationName: "frame", parameters: query,
                resolvedAddresses: [ip], binding: .init(authRef: "public-no-auth", placement: .none)))
        }
    }
    func testNoHeaderInjectionAndMalformedRules() throws {
        var d = declaration(); d.userAgent = "agent\r\nAuthorization: secret"
        XCTAssertThrowsError(try d.validate(alias: "tiles"))
        d = declaration(); d.operations[0].parameters["time"] = .init(location: "path", minimum: 10, maximum: 1)
        XCTAssertThrowsError(try d.validate(alias: "tiles"))
        d = declaration(); d.operations[0].parameters["time"] = .init(location: "path", minimum: 1, maximum: 2, values: ["1"])
        XCTAssertThrowsError(try d.validate(alias: "tiles"))
        XCTAssertThrowsError(try declaration().validate(alias: "home"))
    }
}
