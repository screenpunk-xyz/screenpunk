import Foundation
#if os(macOS)
import Darwin

public protocol WorkspaceDocumentsResolver: Sendable { func documentsDirectory() throws -> URL }
public struct SystemWorkspaceDocumentsResolver: WorkspaceDocumentsResolver {
    public init() {}
    public func documentsDirectory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }
}

public struct WorkspaceExternalBinding: Codable, Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    init(path: String, identity: WorkspaceNodeID) { self.path = path; device = identity.device; inode = identity.inode }
    func validate() throws { guard WorkspaceValidation.absolute(path), inode > 0 else { throw WorkspaceError.invalidSchema } }
}

public struct WorkspaceSelection: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let activePath: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let bindingId: String
    public let rootDevice: UInt64
    public let rootInode: UInt64
    public let externalBindings: [String: WorkspaceExternalBinding]
    init(path: String, workspaceId: String, generation: Int, bindingId: String, root: WorkspaceNodeID,
         externalBindings: [String: WorkspaceExternalBinding] = [:]) {
        schemaVersion = 1; activePath = path; self.workspaceId = workspaceId; selectionGeneration = generation
        self.bindingId = bindingId; rootDevice = root.device; rootInode = root.inode; self.externalBindings = externalBindings
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw schemaVersion > 1 ? WorkspaceError.newerSchema : WorkspaceError.invalidSchema }
        guard WorkspaceValidation.absolute(activePath), WorkspaceValidation.id(workspaceId),
              WorkspaceValidation.id(bindingId), selectionGeneration > 0,
              selectionGeneration <= WorkspaceValidation.maxUInt, rootInode > 0, externalBindings.count <= 10_000,
              externalBindings.allSatisfy({ WorkspaceValidation.id($0.key) && (try? $0.value.validate()) != nil })
        else { throw WorkspaceError.invalidSchema }
    }
}

/// Machine-root path is injected; no constructor opens Application Support or Keychain.
public final class WorkspaceSelectionStore {
    public let machineRootPath: String
    public init(machineRootPath: String) throws {
        guard WorkspaceValidation.absolute(machineRootPath) else { throw WorkspaceError.invalidPath }
        self.machineRootPath = machineRootPath
    }
    private func files(create: Bool) throws -> WorkspaceFiles { try WorkspaceFiles(path: machineRootPath, create: create) }
    public func current() throws -> WorkspaceSelection? { try current(readBudget: nil) }
    func current(readBudget: WorkspaceReadBudget?) throws -> WorkspaceSelection? {
        try readBudget?.check()
        let root: WorkspaceFiles
        do { root = try files(create: false) }
        catch WorkspaceError.unavailable { return nil }
        return try root.locked(readBudget: readBudget) { try read(root, readBudget: readBudget) }
    }
    private func read(_ root: WorkspaceFiles, readBudget: WorkspaceReadBudget? = nil) throws -> WorkspaceSelection? {
        guard try root.exists(root.fd, "bootstrap.json") else { return nil }
        let selection = try WorkspaceJSON.decode(WorkspaceSelection.self,
            from: root.read(root.fd, "bootstrap.json", readBudget: readBudget), shape: .selection)
        try selection.validate(); return selection
    }
    @discardableResult func select(path: String, descriptor: WorkspaceDescriptor, identity: WorkspaceNodeID,
                                   readBudget: WorkspaceReadBudget? = nil,
                                   expectedSelectionGeneration: Int? = nil,
                                   beforeCommit: () throws -> Void = {}) throws -> WorkspaceSelection {
        let root: WorkspaceFiles
        do { root = try files(create: false) }
        catch WorkspaceError.unavailable { root = try files(create: true) }
        return try root.locked(readBudget: readBudget) {
            let previous = try read(root, readBudget: readBudget)
            if let expectedSelectionGeneration,
               previous?.selectionGeneration != expectedSelectionGeneration {
                throw WorkspaceError.conflict
            }
            let generation = (previous?.selectionGeneration ?? 0) + 1
            guard generation <= WorkspaceValidation.maxUInt else { throw WorkspaceError.limitExceeded }
            let sameRoot = previous?.activePath == path && previous?.workspaceId == descriptor.workspaceId &&
                previous?.rootDevice == identity.device && previous?.rootInode == identity.inode
            let next = WorkspaceSelection(path: path, workspaceId: descriptor.workspaceId, generation: generation,
                bindingId: UUID().uuidString.lowercased(), root: identity,
                externalBindings: sameRoot ? previous!.externalBindings : [:])
            let expected = try root.exists(root.fd, "bootstrap.json") ? WorkspaceNodeID(root.metadata(root.fd, "bootstrap.json")) : nil
            try readBudget?.check()
            try beforeCommit()
            try root.write(root.fd, "bootstrap.json", data: WorkspaceJSON.encode(next), expected: expected)
            return next
        }
    }
    @discardableResult func bind(reference: String, path: String, identity: WorkspaceNodeID,
                                 expectedSelection: Int, workspaceId: String) throws -> WorkspaceSelection {
        guard WorkspaceValidation.id(reference) else { throw WorkspaceError.invalidPath }
        let root = try files(create: false)
        return try root.locked {
            guard let current = try read(root), current.selectionGeneration == expectedSelection,
                  current.workspaceId == workspaceId else { throw WorkspaceError.conflict }
            var bindings = current.externalBindings
            bindings[reference] = WorkspaceExternalBinding(path: path, identity: identity)
            guard current.selectionGeneration < WorkspaceValidation.maxUInt else { throw WorkspaceError.limitExceeded }
            let next = WorkspaceSelection(path: current.activePath, workspaceId: current.workspaceId,
                generation: current.selectionGeneration + 1, bindingId: UUID().uuidString.lowercased(),
                root: WorkspaceNodeID(device: current.rootDevice, inode: current.rootInode), externalBindings: bindings)
            let id = WorkspaceNodeID(try root.metadata(root.fd, "bootstrap.json"))
            try root.write(root.fd, "bootstrap.json", data: WorkspaceJSON.encode(next), expected: id)
            return next
        }
    }
    @discardableResult func unbind(reference: String, expectedSelection: Int,
                                   expectedWorkspaceId: String) throws -> WorkspaceSelection {
        let root = try files(create: false)
        return try root.locked {
            guard let current = try read(root), current.workspaceId == expectedWorkspaceId,
                  current.selectionGeneration == expectedSelection,
                  current.externalBindings[reference] != nil,
                  current.selectionGeneration < WorkspaceValidation.maxUInt else { throw WorkspaceError.conflict }
            var bindings = current.externalBindings
            bindings.removeValue(forKey: reference)
            let next = WorkspaceSelection(path: current.activePath, workspaceId: current.workspaceId,
                generation: current.selectionGeneration + 1, bindingId: UUID().uuidString.lowercased(),
                root: WorkspaceNodeID(device: current.rootDevice, inode: current.rootInode), externalBindings: bindings)
            let id = WorkspaceNodeID(try root.metadata(root.fd, "bootstrap.json"))
            try root.write(root.fd, "bootstrap.json", data: WorkspaceJSON.encode(next), expected: id)
            return next
        }
    }
}
#endif
