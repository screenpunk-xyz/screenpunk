import Foundation
import ScreenpunkCore

public struct ControllerSnapshot: Sendable, Equatable, Codable {
    public var controllerIdentity: PairingIdentity
    public var devices: [PairedDevice]
    public var drafts: [StoredRevision]
    public var selectedDeviceId: String?
    public var selectedRevision: String?

    public init(session: WorkbenchSession) {
        controllerIdentity = session.controllerIdentity
        devices = session.devices
        drafts = session.drafts
        selectedDeviceId = session.selectedDeviceId
        selectedRevision = session.selectedRevision
    }

    public func makeSession() -> WorkbenchSession {
        var session = WorkbenchSession(controllerIdentity: controllerIdentity)
        session.devices = devices
        session.drafts = drafts
        session.selectedDeviceId = selectedDeviceId
        session.selectedRevision = selectedRevision
        return session
    }
}

public struct ControllerStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var snapshotURL: URL {
        directory.appendingPathComponent("workbench.json")
    }

    public func save(_ session: WorkbenchSession) throws {
        try AtomicJSONStore.write(ControllerSnapshot(session: session), to: snapshotURL)
    }

    public func load() throws -> WorkbenchSession {
        try AtomicJSONStore.read(ControllerSnapshot.self, from: snapshotURL).makeSession()
    }
}

public enum ControllerPlaceholder: Sendable {
    public static let socketName = "screenpunk-controller.sock"
    public static var schemaMajor: Int { PackageLimits.schemaMajor }
}
