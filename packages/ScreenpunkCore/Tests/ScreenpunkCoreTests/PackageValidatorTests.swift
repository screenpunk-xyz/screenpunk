import XCTest
@testable import ScreenpunkCore

final class PackageValidatorTests: XCTestCase {
    private func manifest(
        entrypoint: String = "index.html",
        files: [ManifestFile]? = nil,
        schema: Int = 1
    ) -> DashboardManifest {
        DashboardManifest(
            schemaVersion: schema,
            dashboardId: "11111111-1111-4111-8111-111111111111",
            name: "Offline fixture",
            revision: "22222222-2222-4222-8222-222222222222",
            entrypoint: entrypoint,
            sdkVersion: "1",
            digest: nil,
            target: ManifestTarget(
                profileId: "fixture-phone",
                width: 390,
                height: 844,
                scale: 3,
                orientation: "portrait"
            ),
            connections: [],
            files: files ?? [
                ManifestFile(
                    path: "index.html",
                    bytes: 12,
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
    }

    func testAcceptsMinimalManifest() throws {
        try PackageValidator.validate(manifest())
    }

    func testRejectsUnsupportedMajorAndMissingEntrypoint() {
        XCTAssertThrowsError(try PackageValidator.validate(manifest(schema: 2))) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.unsupportedVersion), true)
        }
        XCTAssertThrowsError(try PackageValidator.validate(manifest(entrypoint: "missing.html"))) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.missingEntrypoint), true)
        }
    }

    func testRejectsTraversalAndDuplicatePaths() {
        XCTAssertThrowsError(
            try PackageValidator.validate(
                manifest(files: [
                    ManifestFile(path: "../secret", bytes: 1, sha256: String(repeating: "a", count: 64))
                ])
            )
        ) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.pathTraversal), true)
        }
        XCTAssertThrowsError(
            try PackageValidator.validate(
                manifest(files: [
                    ManifestFile(path: "index.html", bytes: 1, sha256: String(repeating: "a", count: 64)),
                    ManifestFile(path: "index.html", bytes: 2, sha256: String(repeating: "b", count: 64))
                ])
            )
        ) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.duplicatePath), true)
        }
    }

    func testNormalizeRejectsTraversalShapesWithoutRegex() {
        let rejected = [
            "../secret",
            "foo/../bar",
            "foo/..",
            "..",
            "foo\\bar",
            "foo\0bar",
            "/etc/passwd",
            "C:windows",
            "c:/abs",
            "%2e%2e/secret",
            "foo/%2E%2E/bar"
        ]
        for path in rejected {
            XCTAssertThrowsError(try PackagePath.normalize(path), path) { error in
                XCTAssertEqual((error as? PackageValidationError)?.issues, [.pathTraversal], path)
            }
        }
    }

    func testNormalizeAcceptsRelativePackagePaths() throws {
        XCTAssertEqual(try PackagePath.normalize("index.html"), "index.html")
        XCTAssertEqual(try PackagePath.normalize("styles/theme.css"), "styles/theme.css")
        XCTAssertEqual(try PackagePath.normalize("foo..bar"), "foo..bar")
    }

    /// The committed schema fixtures are the parity contract with sdk/test/schema.test.ts and package.test.ts.
    func testCommittedFixturesAgreeWithTypeScript() throws {
        let decoder = JSONDecoder()
        let minimal = try decoder.decode(DashboardManifest.self, from: RepoFixtures.data("schemas/fixtures/valid/minimal.json"))
        XCTAssertNoThrow(try PackageValidator.validate(minimal))

        let offline = try decoder.decode(
            DashboardManifest.self,
            from: RepoFixtures.data("examples/offline-fixture/manifest.json")
        )
        XCTAssertNoThrow(try PackageValidator.validate(offline))
        XCTAssertEqual(offline.files.count, 3)
        XCTAssertEqual(offline.digest?.count, 64)
        XCTAssertTrue(offline.connections.isEmpty, "offline example declares no connections, so no Offline ring")

        let expectations: [(String, PackageIssue)] = [
            ("unsupported-major.json", .unsupportedVersion),
            ("missing-entrypoint.json", .missingEntrypoint),
            ("duplicate-path.json", .duplicatePath),
            ("path-traversal.json", .pathTraversal)
        ]
        for (name, issue) in expectations {
            let manifest = try decoder.decode(
                DashboardManifest.self,
                from: RepoFixtures.data("schemas/fixtures/invalid/\(name)")
            )
            XCTAssertThrowsError(try PackageValidator.validate(manifest), name) { error in
                XCTAssertEqual((error as? PackageValidationError)?.issues.contains(issue), true, "\(name) → \(issue)")
            }
        }
    }

    func testRejectsInventoryLimitsAndCredentialShapedNames() {
        let tooMany = (0...PackageLimits.maxFiles).map {
            ManifestFile(path: "f\($0).js", bytes: 1, sha256: String(repeating: "a", count: 64))
        } + [ManifestFile(path: "index.html", bytes: 1, sha256: String(repeating: "a", count: 64))]
        XCTAssertThrowsError(try PackageValidator.validate(manifest(files: tooMany))) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.sizeLimit), true)
        }
        let tooLarge = [
            ManifestFile(path: "index.html", bytes: PackageLimits.expandedBytes + 1, sha256: String(repeating: "a", count: 64))
        ]
        XCTAssertThrowsError(try PackageValidator.validate(manifest(files: tooLarge))) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.sizeLimit), true)
        }
        var leaky = manifest()
        leaky.name = "Weather api_key demo"
        XCTAssertThrowsError(try PackageValidator.validate(leaky)) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.credentialLeak), true)
        }
        var wrongSDK = manifest()
        wrongSDK.sdkVersion = "2"
        XCTAssertThrowsError(try PackageValidator.validate(wrongSDK)) { error in
            XCTAssertEqual((error as? PackageValidationError)?.issues.contains(.validationFailed), true)
        }
        var sideways = manifest()
        sideways.target.orientation = "upside-down"
        XCTAssertThrowsError(try PackageValidator.validate(sideways))
    }

    func testStoreBoundsAndNativeChrome() throws {
        var store = DashboardStore(dashboardId: "dash")
        try store.set(key: "k", json: "1")
        XCTAssertEqual(try store.get(key: "k"), "1")
        XCTAssertTrue(store.usedBytes > 0)
        XCTAssertEqual(UnlinkGestureSpec.actionCount, 1)
        XCTAssertEqual(UnlinkGestureSpec.holdSeconds, 10)
        XCTAssertFalse(OfflineOverlayLayout.usesSystemRed)
        XCTAssertEqual(OfflineOverlayLayout.lightDangerHex, "#A52C42")
        XCTAssertFalse(ConnectionHealth.overlayVisible(requiredFailedOrStale: true, connectionCount: 0))
        XCTAssertTrue(ConnectionHealth.overlayVisible(requiredFailedOrStale: true, connectionCount: 1))
        XCTAssertFalse(RenderReadiness().connectionsHealthy)
        XCTAssertEqual(RuntimeBounds.httpTimeoutSeconds, 15)
        XCTAssertEqual(RuntimeBounds.stateCacheBytes, 5 * 1024 * 1024)
    }
}
