import XCTest
@_spi(NativeInstallation) @testable import ScreenpunkCore
@testable import ScreenpunkApple

final class NativeInstallationStatusTransportTests: XCTestCase {
    func testOriginIsExplicitHTTPSOnly() throws {
        XCTAssertNoThrow(try NativeInstallationStatusTransport(origin: URL(string: "https://staging.example.test")!))
        for text in ["http://staging.example.test", "https://user:pass@staging.example.test", "https://staging.example.test/path", "https://staging.example.test?x=1", "https://staging.example.test#fragment"] {
            XCTAssertThrowsError(try NativeInstallationStatusTransport(origin: URL(string: text)!))
        }
    }
    func testStreamCapCountsAllChunksBeforeAppend() throws {
        let driver = NativeOperationalStatusRequest.Driver(origin: URL(string: "https://staging.example.test")!)
        try driver.append(Data(repeating: 0, count: 16383)); try driver.append(Data([0]))
        XCTAssertThrowsError(try driver.append(Data([0])))
    }
    func testCancelledCollectorCannotAcceptLateBytes() throws {
        let driver = NativeOperationalStatusRequest.Driver(origin: URL(string: "https://staging.example.test")!)
        driver.cancel(); XCTAssertThrowsError(try driver.append(Data([0])))
        driver.cancel()
    }
}
