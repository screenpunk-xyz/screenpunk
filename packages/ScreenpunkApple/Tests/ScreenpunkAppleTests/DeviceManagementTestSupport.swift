import Foundation
import ScreenpunkCore
@testable import ScreenpunkApple

/// Isolated evidence, not an unchecked permission: production authority evaluates these real protocol results.
func testManagementContext() -> DeviceManagementContext {
    let authority = DeviceManagementAuthority(journal: ManagementTestJournal(),
        credentials: CloudInstallationCredentialStore(backend: ManagementTestCredentials(), random: { fatalError("No credential creation in Local tests") }), reset: ManagementTestResetEvidence())
    let lease = try! authority.refresh()!
    return DeviceManagementContext(authority: authority, lease: lease)
}
final class ManagementTestJournal: CloudInstallationTransitionJournal {
    func load() throws -> DeviceManagementTransitionHistory? { nil }
    func save(_ history: DeviceManagementTransitionHistory) throws { fatalError("No Cloud writes in Local tests") }
}
struct ManagementTestCredentials: CloudInstallationCredentialBackend {
    func read(reference: String) throws -> Data? { nil }
    func references() throws -> Set<String> { [] }
    func insert(_ secret: Data, reference: String) throws -> CloudInstallationCredentialInsert { fatalError("No Cloud writes in Local tests") }
}

struct ManagementTestResetEvidence: DeviceLocalResetEvidence {
    let scopeDigest = String(repeating: "a", count: 64)
    func load() throws -> DeviceLocalResetRecord? { nil }
    func save(_ record: DeviceLocalResetRecord) throws { fatalError("No reset writes in Local tests") }
    func beginNewReset(_ record: DeviceLocalResetRecord) throws { fatalError("No reset writes in Local tests") }
}
