import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

enum WorkbenchTransactionCheckpoint: Equatable {
    case journalDurable, beforeMemberMutation(Int), temporaryDurable(Int), memberPublished(Int), generationDurable, beforeCleanup
}

/// Pure final-mutation predicate, also exercised with synthetic descriptor identities.
struct WorkbenchMutationGuard {
    let ancestry: [WorkspaceNodeID]
    let image: WorkbenchTransactionImage
    let node: WorkspaceNodeID?
    func permits(currentAncestry: [WorkspaceNodeID], retainedParent: WorkspaceNodeID,
                 currentImage: WorkbenchTransactionImage, currentNode: WorkspaceNodeID?) -> Bool {
        ancestry == currentAncestry && ancestry.last == retainedParent &&
        image == currentImage && node == currentNode
    }
}

/// The Workspace owner calls this only while its selected-workspace writer is quiesced.
/// Each operation also takes the existing portable root lock, and rechecks the
/// machine-local selection. No portable record can supply a root or plan authority.
final class WorkbenchTransactionEngine {
    private let selection: WorkspaceSelectionStore
    private let inspector: WorkbenchTransactionPlanInspector?
    private let checkpoint: ((WorkbenchTransactionCheckpoint) throws -> Void)?
    private let referenceValidationHook: (() throws -> Void)?
    private let explicitOpen: (path: String, identity: WorkspaceNodeID, workspaceId: String)?
    private let maxPayload = 50 * 1024 * 1024
    private let transactionRoot = ["Workbench", "Transactions"]

    init(selection: WorkspaceSelectionStore, inspector: WorkbenchTransactionPlanInspector? = nil,
         checkpoint: ((WorkbenchTransactionCheckpoint) throws -> Void)? = nil,
         referenceValidationHook: (() throws -> Void)? = nil) {
        self.selection = selection; self.inspector = inspector; self.checkpoint = checkpoint
        self.referenceValidationHook = referenceValidationHook
        explicitOpen = nil
    }

    /// Called only for a host-selected open path before WorkspaceStore.open can
    /// admit a root with pending portable journals. This recovers contained
    /// authoring state; it cannot establish external or destructive authority.
    init(forExplicitOpenAt path: String, selection: WorkspaceSelectionStore,
         checkpoint: ((WorkbenchTransactionCheckpoint) throws -> Void)? = nil) throws {
        let root = try WorkspaceFiles(path: path)
        let descriptor = try WorkspaceJSON.decode(WorkspaceDescriptor.self,
            from: root.read(root.fd, "workspace.json"), shape: .descriptor)
        try descriptor.validate()
        self.selection = selection; inspector = nil; self.checkpoint = checkpoint
        referenceValidationHook = nil
        explicitOpen = (path, root.identity, descriptor.workspaceId)
    }

    /// `blobs` is already-bounded caller data, indexed by its measured SHA-256.
    /// Blob files are durable before the journal becomes visible to recovery.
    func prepare(_ journal: WorkbenchTransactionJournal, blobs: [String: Data]) throws {
        guard explicitOpen == nil else { throw WorkspaceError.conflict }
        let encoded = try WorkbenchTransactionJSON.encode(journal)
        let (root, selected) = try selectedRoot()
        try root.locked {
            try verifySelection(root, selected)
            do {
                let transactions = try root.directory(transactionRoot); defer { close(transactions) }
                guard try entries(transactions).isEmpty else { throw WorkspaceError.conflict }
            }
            let loaded = try loadContext(root, journal, stagedBlobs: blobs)
            guard loaded.roots.allSatisfy({ $0 == nil || $0!.identity.device == root.identity.device }) else {
                throw WorkspaceError.conflict // Cross-volume temporary ownership is not recoverable yet.
            }
            try validatePlan(journal, selected, externalIDs: loaded.externalIDs)
            let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 120,
                                             cancelled: { false })
            try validateImagesAndTargets(root, selected, journal, context: loaded,
                                         stagedBlobs: blobs, budget: budget)
            guard try descriptor(root).generation == journal.expectedGeneration else { throw WorkspaceError.conflict }
            let parent = try root.directory(transactionRoot); defer { close(parent) }
            guard try descriptorMatches(root, path: transactionRoot, opened: parent) else { throw WorkspaceError.conflict }
            guard try !collisionCheckedExists(parent, journal.transactionId) else { throw WorkspaceError.conflict }
            guard mkdirat(parent, journal.transactionId, 0o700) == 0, fsync(parent) == 0 else {
                throw errno == EEXIST ? WorkspaceError.conflict : WorkspaceError.unavailable
            }
            let stage = try root.directory(transactionRoot + [journal.transactionId]); defer { close(stage) }
            guard try descriptorMatches(root, path: transactionRoot + [journal.transactionId], opened: stage) else {
                throw WorkspaceError.conflict
            }
            guard mkdirat(stage, "blobs", 0o700) == 0, fsync(stage) == 0 else { throw WorkspaceError.unavailable }
            guard mkdirat(stage, "work", 0o700) == 0, fsync(stage) == 0 else { throw WorkspaceError.unavailable }
            let blobDirectory = try root.directory(transactionRoot + [journal.transactionId, "blobs"])
            defer { close(blobDirectory) }
            for (hash, data) in blobs.sorted(by: { $0.key < $1.key }) {
                try writeNew(blobDirectory, hash, data: data)
            }
            guard try descriptorMatches(root, path: transactionRoot + [journal.transactionId], opened: stage),
                  try descriptorMatches(root, path: transactionRoot + [journal.transactionId, "blobs"], opened: blobDirectory)
            else { throw WorkspaceError.conflict }
            try root.write(stage, "journal.json", data: encoded, expected: nil)
            try checkpoint?(.journalDurable)
        }
    }

    /// Complete one prepared journal. A thrown checkpoint simulates process death:
    /// durable stage and partial target writes are deliberately retained for replay.
    func commit(_ transactionId: String) throws {
        guard explicitOpen == nil else { throw WorkspaceError.conflict }
        guard WorkspaceValidation.id(transactionId) else { throw WorkspaceError.invalidPath }
        let (root, selected) = try selectedRoot()
        try root.locked {
            try verifySelection(root, selected)
            do {
                let transactions = try root.directory(transactionRoot); defer { close(transactions) }
                guard try entries(transactions) == [transactionId] else { throw WorkspaceError.conflict }
            }
            let journal = try readJournal(root, transactionId)
            try apply(root, selected, journal)
        }
    }

    /// First parse and validate every discovered journal and its blobs. A hostile
    /// unknown entry blocks recovery before any transaction gets replayed.
    func recoverAll() throws -> [String] {
        let (root, selected) = try selectedRoot()
        return try root.locked {
            try verifySelection(root, selected)
            let transactions = try root.directory(transactionRoot); defer { close(transactions) }
            let names = try entries(transactions)
            guard names.count <= 2_000 else { throw WorkspaceError.limitExceeded }
            var spelling = Set<String>()
            for name in names {
                guard spelling.insert(WorkspaceValidation.portableKey(name)).inserted else { throw WorkspaceError.conflict }
            }
            var journals: [WorkbenchTransactionJournal] = []
            var generations = Set<Int>()
            var aggregateBytes: Int64 = 0, aggregateOperations = 0
            for name in names {
                do {
                    guard WorkspaceValidation.id(name) else { throw WorkspaceError.incomplete }
                    let journal = try readJournal(root, name)
                    guard generations.insert(journal.expectedGeneration).inserted else { throw WorkspaceError.conflict }
                    aggregateOperations += journal.operations.count
                    guard aggregateOperations <= 1_000_000 else { throw WorkspaceError.limitExceeded }
                    aggregateBytes += Int64(try validateBlobs(root, journal, stagedBlobs: nil))
                    guard aggregateBytes <= 64 * 1024 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
                    journals.append(journal)
                } catch { throw diagnostic(name, error) }
            }
            journals.sort { ($0.expectedGeneration, $0.transactionId) < ($1.expectedGeneration, $1.transactionId) }
            for journal in journals {
                do { try apply(root, selected, journal) }
                catch { throw diagnostic(journal.transactionId, error) }
            }
            return journals.map(\.transactionId)
        }
    }

    private func diagnostic(_ name: String, _ error: Error) -> WorkbenchTransactionFailure {
        WorkbenchTransactionFailure(transactionId: WorkspaceValidation.id(name) ? name : nil,
                                    reason: error as? WorkspaceError ?? .unavailable)
    }

    private struct Context {
        let catalog: WorkspaceCatalog
        let paths: [[String]]
        let roots: [WorkspaceFiles?]
        let externalIDs: Set<String>
    }

    private func selectedRoot() throws -> (WorkspaceFiles, WorkspaceSelection) {
        if let explicitOpen {
            let root = try WorkspaceFiles(path: explicitOpen.path)
            guard root.identity == explicitOpen.identity,
                  try descriptor(root).workspaceId == explicitOpen.workspaceId else { throw WorkspaceError.conflict }
            let candidate = WorkspaceSelection(path: root.path, workspaceId: explicitOpen.workspaceId,
                generation: 1, bindingId: "explicit-recovery", root: explicitOpen.identity)
            try verifySelection(root, candidate)
            return (root, candidate)
        }
        guard let selected = try selection.current() else { throw WorkspaceError.unavailable }
        let root = try WorkspaceFiles(path: selected.activePath)
        try verifySelection(root, selected)
        return (root, selected)
    }
    private func verifySelection(_ root: WorkspaceFiles, _ selected: WorkspaceSelection) throws {
        if let explicitOpen {
            guard root.path == explicitOpen.path, root.identity == explicitOpen.identity,
                  selected.workspaceId == explicitOpen.workspaceId else { throw WorkspaceError.conflict }
            try root.verifyRoot()
            guard try descriptor(root).workspaceId == explicitOpen.workspaceId else { throw WorkspaceError.conflict }
            return
        }
        guard root.path == selected.activePath, root.identity.device == selected.rootDevice,
              root.identity.inode == selected.rootInode,
              try selection.current() == selected else { throw WorkspaceError.conflict }
        try root.verifyRoot()
        guard try descriptor(root).workspaceId == selected.workspaceId else { throw WorkspaceError.conflict }
    }
    private func descriptor(_ root: WorkspaceFiles) throws -> WorkspaceDescriptor {
        let value = try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: root.read(root.fd, "workspace.json"), shape: .descriptor)
        try value.validate(); return value
    }
    private func catalog(_ root: WorkspaceFiles) throws -> WorkspaceCatalog {
        let parent = try root.directory(["Workbench", "Library"]); defer { close(parent) }
        let value = try WorkspaceJSON.decode(WorkspaceCatalog.self, from: root.read(parent, "catalog.json"), shape: .catalog)
        try value.validate(); return value
    }

    private func loadContext(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                             stagedBlobs: [String: Data]? = nil) throws -> Context {
        try journal.validate()
        guard try descriptor(root).workspaceId == journal.workspaceId else { throw WorkspaceError.conflict }
        let currentCatalog = try catalog(root)
        let catalog: WorkspaceCatalog
        if journal.kind == .sourceCommit,
           let proposed = journal.operations.first(where: { $0.target.object == "libraryCatalog" }) {
            guard let hash = proposed.recoveryBlobHash else { throw WorkspaceError.invalidSchema }
            let bytes = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
            catalog = try WorkspaceJSON.decode(WorkspaceCatalog.self, from: bytes, shape: .catalog)
            try catalog.validate()
            let projectID = journal.operations.first(where: { $0.target.targetClass == "projectMember" })?.target.projectId
            guard catalog.archivedDashboardIds == currentCatalog.archivedDashboardIds,
                  (catalog.projects == currentCatalog.projects &&
                   (currentCatalog.generation <= journal.expectedGeneration ||
                    currentCatalog.generation == catalog.generation)) ||
                (currentCatalog.generation <= journal.expectedGeneration &&
                 catalog.projects.count == currentCatalog.projects.count + 1 &&
                 catalog.projects.prefix(currentCatalog.projects.count).elementsEqual(currentCatalog.projects) &&
                 catalog.projects.last?.projectId == projectID) ||
                (projectID.map { WorkbenchScreenCatalogRename.matches(before: currentCatalog,
                    after: catalog, projectId: $0,
                    expectedGeneration: journal.expectedGeneration) ||
                    WorkbenchScreenCatalogAssociation.matches(before: currentCatalog,
                        after: catalog, projectId: $0,
                        expectedGeneration: journal.expectedGeneration) } ?? false)
            else { throw WorkspaceError.conflict }
        } else { catalog = currentCatalog }
        var paths: [[String]] = [], roots: [WorkspaceFiles?] = [], externalIDs = Set<String>()
        var collisions = Set<String>()
        for op in journal.operations {
            let target = op.target
            var parts: [String]
            var alternate: WorkspaceFiles? = nil
            switch (journal.kind, target.targetClass) {
            case (.projectEdit, "projectMember"), (.sourceCommit, "projectMember"):
                guard let project = catalog.projects.first(where: { $0.projectId == target.projectId }),
                      let member = target.member else { throw WorkspaceError.conflict }
                if let path = project.location.path {
                    parts = path.split(separator: "/").map(String.init) + member.split(separator: "/").map(String.init)
                } else {
                    guard explicitOpen == nil else { throw WorkspaceError.conflict }
                    guard let reference = project.location.referenceId,
                          let binding = try selection.current()?.externalBindings[reference],
                          WorkspaceValidation.absolute(binding.path),
                          disjoint(binding.path, root.path), disjoint(binding.path, selection.machineRootPath)
                    else { throw WorkspaceError.conflict }
                    let source = try WorkspaceFiles(path: binding.path, requiredPrivateRoot: false)
                    guard source.identity.device == binding.device, source.identity.inode == binding.inode else {
                        throw WorkspaceError.conflict
                    }
                    externalIDs.insert(project.projectId); alternate = source
                    parts = member.split(separator: "/").map(String.init)
                }
                if op.after.state == "absent" {
                    guard target.member != "screenpunk.project.json", target.member != "screen.json" else {
                        throw WorkspaceError.invalidSchema
                    }
                }
            case (.catalogSettingsCommit, "portableMetadata"), (.sourceCommit, "portableMetadata"),
                 (.historyPublish, "portableMetadata"):
                switch target.object {
                case "workspaceDescriptor": parts = ["workspace.json"]
                case "libraryCatalog": parts = ["Workbench", "Library", "catalog.json"]
                case "workbenchSettings": parts = ["Workbench", "Settings", "workbench.json"]
                case "toolchainRequirements": parts = ["Workbench", "Toolchains", "requirements.json"]
                case "logicalConnections": parts = ["Workbench", "Settings", "connections.json"]
                default: throw WorkspaceError.invalidSchema
                }
            case (.historyPublish, "historyObject"), (.historyPrune, "historyObject"),
                 (.sourceCommit, "historyObject"), (.packageHeadCommit, "historyObject"):
                guard let objectKind = target.objectKind, let objectId = target.objectId,
                      let member = target.member else { throw WorkspaceError.invalidSchema }
                let base: [String]
                switch objectKind {
                case "buildSource": base = ["Workbench", "History", "Builds", objectId, "source"]
                case "package": base = ["Workbench", "History", "Packages", objectId]
                case "preparedPackage": base = ["Workbench", "History", "Prepared", objectId]
                case "deploymentHistory": base = ["Workbench", "History", "Deployments", objectId]
                case "attachment": base = ["Workbench", "Attachments", objectId]
                default: throw WorkspaceError.invalidSchema
                }
                parts = base + member.split(separator: "/").map(String.init)
            case (.packageHeadCommit, "buildHead"):
                guard let projectId = target.projectId else { throw WorkspaceError.invalidSchema }
                parts = ["Workbench", "Library", "BuildHeads", projectId + ".json"]
            case (.migrationPublish, "migrationStagingObject"):
                guard let migrationId = target.migrationId, let objectKind = target.objectKind,
                      let objectId = target.objectId, let member = target.member else { throw WorkspaceError.invalidSchema }
                parts = ["Workbench", "Migrations", migrationId, "Staging", objectKind, objectId]
                    + member.split(separator: "/").map(String.init)
            default: throw WorkspaceError.invalidSchema
            }
            guard parts.count <= 32, parts.allSatisfy({ WorkspaceValidation.member($0) && !$0.contains("/") }) else {
                throw WorkspaceError.invalidPath
            }
            let key = (alternate == nil ? "workspace:" : "external:\(target.projectId ?? ""):")
                + WorkspaceValidation.portableKey(parts.joined(separator: "/"))
            guard collisions.insert(key).inserted else { throw WorkspaceError.conflict }
            paths.append(parts); roots.append(alternate)
        }
        return Context(catalog: catalog, paths: paths, roots: roots, externalIDs: externalIDs)
    }

    private func disjoint(_ a: String, _ b: String) -> Bool {
        let one = WorkspaceValidation.portableKey(a), two = WorkspaceValidation.portableKey(b)
        return one != two && !one.hasPrefix(two + "/") && !two.hasPrefix(one + "/")
    }
    private func validatePlan(_ journal: WorkbenchTransactionJournal, _ selectionValue: WorkspaceSelection,
                              externalIDs: Set<String>) throws {
        guard journal.kind == .historyPrune || journal.kind == .migrationPublish || !externalIDs.isEmpty else { return }
        guard explicitOpen == nil else { throw WorkspaceError.conflict }
        guard let plan = try inspector?.currentPlan(transactionId: journal.transactionId),
              plan.transactionId == journal.transactionId, plan.kind == journal.kind,
              plan.workspaceId == journal.workspaceId, plan.bindingId == selectionValue.bindingId,
              plan.selectionGeneration == selectionValue.selectionGeneration,
              plan.expectedGeneration == journal.expectedGeneration,
              plan.reviewedExternalProjectIds.isSuperset(of: externalIDs),
              canonicalOperations(plan.operations) == canonicalOperations(journal.operations),
              (journal.kind != .historyPrune || plan.prunableHistoryTargets == Set(journal.operations.map { targetKey($0.target) })),
              (journal.kind != .migrationPublish || plan.verifiedMigrationTargets == Set(journal.operations.map { targetKey($0.target) }))
        else { throw WorkspaceError.conflict }
    }
    private func targetKey(_ target: WorkbenchTransactionTarget) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(target)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private func canonicalOperations(_ operations: [WorkbenchTransactionOperation]) -> [String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return operations.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.sorted()
    }

    private func readJournal(_ root: WorkspaceFiles, _ id: String) throws -> WorkbenchTransactionJournal {
        let stage = try root.directory(transactionRoot + [id]); defer { close(stage) }
        guard Set(try entries(stage)) == ["journal.json", "blobs", "work"] else { throw WorkspaceError.incomplete }
        let bytes = try root.read(stage, "journal.json")
        let journal = try WorkbenchTransactionJSON.decode(bytes)
        guard journal.transactionId == id else { throw WorkspaceError.conflict }
        return journal
    }
    private func validateImagesAndTargets(_ root: WorkspaceFiles, _ selected: WorkspaceSelection,
                                          _ journal: WorkbenchTransactionJournal, context: Context,
                                          stagedBlobs: [String: Data]?, budget: WorkspaceReadBudget,
                                          requireCurrentPublicationBinding: Bool = true) throws {
        _ = try validateBlobs(root, journal, stagedBlobs: stagedBlobs)
        try validateMetadataPayloads(root, journal, stagedBlobs: stagedBlobs)
        try validateProjectPayloads(root, journal, context: context, stagedBlobs: stagedBlobs)
        try validateSourceCommit(root, journal, context: context, stagedBlobs: stagedBlobs)
        try validatePackageHead(root, journal, context: context, stagedBlobs: stagedBlobs,
                                budget: budget, requireCurrentBinding: requireCurrentPublicationBinding)
        try validateHistoryQuotas(root, journal, context: context)
        for (index, op) in journal.operations.enumerated() {
            let anchor = context.roots[index] ?? root
            let current = try image(anchor, context.paths[index])
            guard current == op.before || current == op.after else { throw WorkspaceError.conflict }
        }
        try verifySelection(root, selected)
    }

    @discardableResult private func validateBlobs(_ root: WorkspaceFiles,
                                                  _ journal: WorkbenchTransactionJournal,
                                                  stagedBlobs: [String: Data]?) throws -> Int {
        var total = 0
        var measured: [String: Int] = [:]
        let required = Set(journal.operations.compactMap(\.recoveryBlobHash))
        if let stagedBlobs { guard Set(stagedBlobs.keys) == required else { throw WorkspaceError.invalidSchema } }
        else {
            let folder = try root.directory(transactionRoot + [journal.transactionId, "blobs"])
            defer { close(folder) }
            guard Set(try entries(folder)) == required else { throw WorkspaceError.incomplete }
        }
        for hash in required {
            guard WorkspaceValidation.sha256(hash) else { throw WorkspaceError.invalidSchema }
            let data = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
            guard data.count <= maxPayload, WorkbenchTransactionDigest.hex(data) == hash,
                  journal.operations.filter({ $0.recoveryBlobHash == hash }).allSatisfy({ $0.after.bytes == data.count })
            else { throw WorkspaceError.conflict }
            guard data.count <= maxPayload - total else { throw WorkspaceError.limitExceeded }
            total += data.count
            measured[hash] = data.count
        }
        _ = try WorkbenchTransactionAccounting.expandedPublicationBytes(journal.operations,
            measuredBlobs: measured, kind: journal.kind)
        if stagedBlobs == nil { try validateWork(root, journal) }
        return total
    }

    private func validateWork(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal) throws {
        let work = try root.directory(transactionRoot + [journal.transactionId, "work"])
        defer { close(work) }
        let names = try entries(work)
        guard names.count <= journal.operations.count + 1 else { throw WorkspaceError.limitExceeded }
        for name in names {
            guard let index = Int(name), String(index) == name,
                  index >= 0, index <= journal.operations.count else { throw WorkspaceError.invalidSchema }
            let bytes = try readRegular(work, name, max: maxPayload)
            if index == journal.operations.count {
                guard journal.kind != .catalogSettingsCommit,
                      !journal.operations.contains(where: { $0.target.object == "workspaceDescriptor" })
                else { throw WorkspaceError.invalidSchema }
                let value = try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: bytes, shape: .descriptor)
                try value.validate()
                guard value.workspaceId == journal.workspaceId,
                      value.generation == journal.expectedGeneration + 1 else { throw WorkspaceError.conflict }
            } else {
                let after = journal.operations[index].after
                guard after.state == "present", after.bytes == bytes.count,
                      after.sha256 == WorkbenchTransactionDigest.hex(bytes) else { throw WorkspaceError.conflict }
            }
        }
    }

    private func validateMetadataPayloads(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                                          stagedBlobs: [String: Data]?) throws {
        guard journal.kind == .catalogSettingsCommit || journal.kind == .sourceCommit ||
              journal.kind == .historyPublish else { return }
        let old = try descriptor(root)
        for op in journal.operations where op.target.targetClass == "portableMetadata" {
            guard let name = op.target.object, let hash = op.recoveryBlobHash else { throw WorkspaceError.invalidSchema }
            let data = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
            switch name {
            case "workspaceDescriptor":
                let value = try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: data, shape: .descriptor)
                try value.validate()
                guard value.workspaceId == old.workspaceId, value.schemaVersion == old.schemaVersion,
                      value.paths == old.paths, value.recovery == old.recovery,
                      value.generation == journal.expectedGeneration + 1 else { throw WorkspaceError.conflict }
            case "libraryCatalog":
                let value = try WorkspaceJSON.decode(WorkspaceCatalog.self, from: data, shape: .catalog)
                try value.validate()
                guard value.generation == journal.expectedGeneration + 1 else { throw WorkspaceError.conflict }
                if journal.kind == .catalogSettingsCommit { try validateCatalogReferences(root, value) }
                if journal.kind == .historyPublish {
                    let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
                    let current = try WorkspaceJSON.decode(WorkspaceCatalog.self,
                        from: root.read(library, "catalog.json"), shape: .catalog)
                    guard value.projects == current.projects else { throw WorkspaceError.conflict }
                }
            case "workbenchSettings":
                let value = try WorkspaceJSON.decode(WorkspaceSettings.self, from: data, shape: .settings)
                try value.validate()
                guard value.generation == journal.expectedGeneration + 1 else { throw WorkspaceError.conflict }
                if journal.kind == .historyPublish {
                    let folder = try root.directory(["Workbench", "Settings"]); defer { close(folder) }
                    let current = try WorkspaceJSON.decode(WorkspaceSettings.self,
                        from: root.read(folder, "workbench.json"), shape: .settings)
                    guard value.presentation == current.presentation,
                          value.profiles == current.profiles else { throw WorkspaceError.conflict }
                }
            case "toolchainRequirements":
                guard journal.kind == .sourceCommit else { throw WorkspaceError.invalidSchema }
                let value = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
                    from: data, shape: .requirements)
                try value.validate()
            case "logicalConnections":
                let value = try WorkspaceJSON.decode(WorkspaceConnections.self, from: data, shape: .connections)
                try value.validate()
            default: throw WorkspaceError.invalidSchema
            }
        }
    }

    private func validateCatalogReferences(_ root: WorkspaceFiles, _ catalog: WorkspaceCatalog) throws {
        var members = 0
        for project in catalog.projects {
            guard let path = project.location.path else { continue } // External source is never inferred from portable IDs.
            let folder = path.split(separator: "/").map(String.init)
            let fd = try root.directory(folder); defer { close(fd) }
            let bytes = try root.read(fd, "screenpunk.project.json")
            let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self, from: bytes, shape: .project)
            try document.validate(matching: project)
            let remaining = 1_000_000 - members
            guard remaining > 0 else { throw WorkspaceError.limitExceeded }
            let inventory = try root.inventory(folder, memberLimit: remaining,
                required: ["screenpunk.project.json", document.screenConfig, document.entry])
            members += inventory.members
        }
        try referenceValidationHook?()
    }

    private func validateMetadataPostconditions(_ root: WorkspaceFiles,
                                                _ journal: WorkbenchTransactionJournal,
                                                _ context: Context) throws {
        guard journal.kind == .catalogSettingsCommit ||
              (journal.kind == .historyPublish && journal.schemaVersion == 2) ||
              (journal.kind == .sourceCommit && journal.operations.contains(where: { $0.target.object == "libraryCatalog" }))
        else { return }
        guard let catalogIndex = journal.operations.firstIndex(where: { $0.target.object == "libraryCatalog" }) else {
            throw WorkspaceError.invalidSchema
        }
        for index in journal.operations.indices where journal.operations[index].target.targetClass == "portableMetadata" &&
            journal.operations[index].target.object != "workspaceDescriptor" {
            guard try image(root, context.paths[index]) == journal.operations[index].after else {
                throw WorkspaceError.conflict
            }
        }
        let parent = try root.directory(["Workbench", "Library"]); defer { close(parent) }
        let data = try root.read(parent, "catalog.json")
        guard WorkbenchTransactionImage.present(data) == journal.operations[catalogIndex].after else {
            throw WorkspaceError.conflict
        }
        let projected = try WorkspaceJSON.decode(WorkspaceCatalog.self, from: data, shape: .catalog)
        try projected.validate()
        try validateCatalogReferences(root, projected)
    }

    private func validateProjectPayloads(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                                         context: Context, stagedBlobs: [String: Data]?) throws {
        guard journal.kind == .projectEdit || journal.kind == .sourceCommit else { return }
        let ids = Set(journal.operations.compactMap(\.target.projectId))
        for id in ids {
            guard let project = context.catalog.projects.first(where: { $0.projectId == id }) else {
                throw WorkspaceError.conflict
            }
            let indices = journal.operations.indices.filter {
                journal.operations[$0].target.targetClass == "projectMember" && journal.operations[$0].target.projectId == id
            }
            guard let first = indices.first else { continue }
            let anchor = context.roots[first] ?? root
            let rootParts = Array(context.paths[first].dropLast(journal.operations[first].target.member!.split(separator: "/").count))
            let descriptorIndex = indices.first { journal.operations[$0].target.member == "screenpunk.project.json" }
            let descriptorBytes: Data
            if let descriptorIndex {
                let op = journal.operations[descriptorIndex]
                guard let hash = op.recoveryBlobHash else { throw WorkspaceError.invalidSchema }
                descriptorBytes = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
            } else {
                guard let fd = try parent(anchor, rootParts + ["screenpunk.project.json"], create: false) else {
                    throw WorkspaceError.incomplete
                }
                defer { close(fd) }
                descriptorBytes = try readRegular(fd, "screenpunk.project.json", max: 8 * 1024 * 1024)
            }
            let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self, from: descriptorBytes, shape: .project)
            try document.validate(matching: project)
            let currentRules = try WorkspaceIgnoreRules(root: anchor, project: rootParts)
            let projectedSource: WorkspaceIgnoreSource
            if let ignoreIndex = indices.first(where: { journal.operations[$0].target.member == ".screenpunkignore" }) {
                let ignore = journal.operations[ignoreIndex]
                if ignore.after.state == "absent" { projectedSource = .absent }
                else {
                    guard let hash = ignore.recoveryBlobHash else { throw WorkspaceError.invalidSchema }
                    projectedSource = .staged(try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash))
                }
            } else { projectedSource = .current }
            let projectedRules: WorkspaceIgnoreRules
            switch projectedSource {
            case .current: projectedRules = currentRules
            case .absent: projectedRules = try WorkspaceIgnoreRules(data: nil)
            case .staged(let data): projectedRules = try WorkspaceIgnoreRules(data: data)
            }
            let requiredPaths = ["screenpunk.project.json", document.screenConfig, document.entry] +
                (projectedRules.hasFile ? [".screenpunkignore"] : [])
            try WorkspaceProjectedSourcePolicy.validate(current: currentRules, projected: projectedRules,
                targets: indices.compactMap { journal.operations[$0].target.member }, required: requiredPaths)
            for required in requiredPaths {
                if let index = indices.first(where: { journal.operations[$0].target.member == required }) {
                    guard journal.operations[index].after.state == "present" else { throw WorkspaceError.invalidSchema }
                } else {
                    guard try image(anchor, rootParts + required.split(separator: "/").map(String.init)).state == "present" else {
                        throw WorkspaceError.incomplete
                    }
                }
            }
            let currentInventory = try anchor.inventory(rootParts, memberLimit: 2_000, ignoreSource: projectedSource)
            var projectedBytes = currentInventory.bytes
            var projectedFiles = currentInventory.files
            var projectedMembers = currentInventory.members
            var projectedDirectories = currentInventory.directories
            for index in indices {
                let operation = journal.operations[index]
                guard operation.after.state == "absent" || (operation.after.bytes ?? 0) <= 5 * 1024 * 1024 else {
                    throw WorkspaceError.limitExceeded
                }
                let actual = try image(anchor, context.paths[index])
                guard actual == operation.before || actual == operation.after else { throw WorkspaceError.conflict }
                if actual == operation.after { continue }
                let priorBytes = actual.bytes ?? 0, nextBytes = operation.after.bytes ?? 0
                projectedBytes += Int64(nextBytes - priorBytes)
                if actual.state == "absent", operation.after.state == "present" {
                    projectedFiles += 1
                    projectedMembers += 1
                    let parts = operation.target.member!.split(separator: "/").map(String.init)
                    for length in 1..<parts.count {
                        if projectedDirectories.insert(parts.prefix(length).joined(separator: "/")).inserted {
                            projectedMembers += 1
                        }
                    }
                } else if actual.state == "present", operation.after.state == "absent" {
                    projectedFiles -= 1
                    projectedMembers -= 1 // The directory itself is retained.
                }
            }
            guard projectedBytes >= 0, projectedBytes <= 25 * 1024 * 1024,
                  projectedFiles >= 0, projectedFiles <= 2_000, projectedMembers <= 2_000 else {
                throw WorkspaceError.limitExceeded
            }
        }
    }

    /// A V2 source commit carries the complete included postimage twice: as the
    /// project members and as an immutable build-source object. Recovery accepts
    /// mixed before/after members, but never fabricates a history claim from a
    /// journal label or publishes a catalog entry without its complete source.
    private func validateSourceCommit(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                                      context: Context, stagedBlobs: [String: Data]?) throws {
        guard journal.kind == .sourceCommit else { return }
        let projectOperations = journal.operations.filter { $0.target.targetClass == "projectMember" }
        guard let projectID = projectOperations.first?.target.projectId,
              let project = context.catalog.projects.first(where: { $0.projectId == projectID }),
              let relative = project.location.path else { throw WorkspaceError.conflict }
        let folderParts = relative.split(separator: "/").map(String.init)
        let existing = try root.inventory(folderParts, memberLimit: 2_000)
        let targets = Set(projectOperations.compactMap(\.target.member))
        guard Set(existing.includedFiles).isSubset(of: targets) else { throw WorkspaceError.conflict }
        var files: [String: Data] = [:]
        for operation in projectOperations where operation.after.state == "present" {
            guard let member = operation.target.member, let hash = operation.recoveryBlobHash else {
                throw WorkspaceError.invalidSchema
            }
            files[member] = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
        }
        guard let descriptorBytes = files["screenpunk.project.json"], let config = files["screen.json"],
              (try? JSONSerialization.jsonObject(with: config)) is [String: Any] else {
            throw WorkspaceError.invalidSchema
        }
        let document = try WorkspaceJSON.decode(WorkspaceProjectDocument.self, from: descriptorBytes, shape: .project)
        try document.validate(matching: project)
        guard files[document.entry] != nil else { throw WorkspaceError.invalidSchema }
        let version = try WorkbenchSourceHasher.hash(files)
        let history = journal.operations.filter { $0.target.targetClass == "historyObject" }
        guard history.allSatisfy({ $0.target.objectId == version }),
              Set(history.compactMap(\.target.member)) == Set(files.keys).union([".screenpunk-snapshot.json"]),
              let metadataOperation = history.first(where: { $0.target.member == ".screenpunk-snapshot.json" }),
              let metadataHash = metadataOperation.recoveryBlobHash else { throw WorkspaceError.conflict }
        for operation in history where operation.target.member != ".screenpunk-snapshot.json" {
            guard let member = operation.target.member, let bytes = files[member],
                  operation.after == .present(bytes) else { throw WorkspaceError.conflict }
        }
        let metadataBytes = try stagedBlobs?[metadataHash] ?? readBlob(root, journal.transactionId, metadataHash)
        guard let raw = try JSONSerialization.jsonObject(with: metadataBytes) as? [String: Any],
              Set(raw.keys) == ["sourceVersion", "sourceHashVersion", "projectId", "dashboardId", "files"],
              let rows = raw["files"] as? [[String: Any]], rows.allSatisfy({
                  Set($0.keys) == ["path", "sha256", "bytes"]
              }) else { throw WorkspaceError.invalidSchema }
        let metadata = try JSONDecoder().decode(WorkbenchSourceHistoryEntry.self, from: metadataBytes)
        guard metadata.sourceVersion == version, metadata.sourceHashVersion == 1,
              metadata.projectId == projectID, metadata.dashboardId == project.dashboardId,
              metadata.files.count == files.count,
              Set(metadata.files.map(\.path)) == Set(files.keys) else { throw WorkspaceError.conflict }
        for item in metadata.files {
            guard let bytes = files[item.path], item.bytes == bytes.count,
                  item.sha256 == WorkbenchTransactionDigest.hex(bytes) else { throw WorkspaceError.conflict }
        }
        let metadataNames = Set(journal.operations.compactMap { $0.target.targetClass == "portableMetadata" ? $0.target.object : nil })
        if !metadataNames.isEmpty {
            guard metadataNames == ["workspaceDescriptor", "libraryCatalog", "workbenchSettings"] ||
                    metadataNames == ["workspaceDescriptor", "libraryCatalog", "workbenchSettings", "toolchainRequirements"],
                  let catalogOperation = journal.operations.first(where: { $0.target.object == "libraryCatalog" })
            else { throw WorkspaceError.conflict }
            if metadataNames.contains("toolchainRequirements") {
                guard document.kind == "react", let lockBytes = files["screenpunk.lock.json"],
                      let raw = try JSONSerialization.jsonObject(with: lockBytes) as? [String: Any],
                      Set(raw.keys) == ["schemaVersion", "catalogEntryId", "kitVersion", "platform", "inventoryHash"]
                else { throw WorkspaceError.invalidSchema }
                let pin = try JSONDecoder().decode(WorkbenchSourceKitPin.self, from: lockBytes)
                guard pin.schemaVersion == 1, pin.kitVersion == document.kitVersion else {
                    throw WorkspaceError.conflict
                }
                let requirementsOperation = journal.operations.first { $0.target.object == "toolchainRequirements" }!
                guard let hash = requirementsOperation.recoveryBlobHash else { throw WorkspaceError.invalidSchema }
                let proposedBytes = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
                let proposed = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
                    from: proposedBytes, shape: .requirements)
                try proposed.validate()
                guard proposed.required.contains(pin.requirement) else { throw WorkspaceError.conflict }
                let toolchains = try root.directory(["Workbench", "Toolchains"]); defer { close(toolchains) }
                let currentBytes = try root.read(toolchains, "requirements.json")
                let currentImage = WorkbenchTransactionImage.present(currentBytes)
                guard currentImage == requirementsOperation.before || currentImage == requirementsOperation.after else {
                    throw WorkspaceError.conflict
                }
                if currentImage == requirementsOperation.before {
                    let current = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
                        from: currentBytes, shape: .requirements)
                    try current.validate()
                    guard proposed.required == current.required ||
                            proposed.required == current.required + [pin.requirement] else {
                        throw WorkspaceError.conflict
                    }
                }
            }
            let library = try root.directory(["Workbench", "Library"]); defer { close(library) }
            let currentBytes = try root.read(library, "catalog.json")
            let currentCatalog = try WorkspaceJSON.decode(WorkspaceCatalog.self,
                from: currentBytes, shape: .catalog)
            let currentImage = WorkbenchTransactionImage.present(currentBytes)
            if currentImage == catalogOperation.before {
                if currentCatalog.projects.contains(where: { $0.projectId == projectID }) {
                    guard context.catalog.archivedDashboardIds == currentCatalog.archivedDashboardIds,
                          context.catalog.projects == currentCatalog.projects ||
                        WorkbenchScreenCatalogRename.matches(before: currentCatalog,
                            after: context.catalog, projectId: projectID,
                            expectedGeneration: journal.expectedGeneration) ||
                        WorkbenchScreenCatalogAssociation.matches(before: currentCatalog,
                            after: context.catalog, projectId: projectID,
                            expectedGeneration: journal.expectedGeneration) else {
                        throw WorkspaceError.conflict
                    }
                } else {
                    guard context.catalog.archivedDashboardIds == currentCatalog.archivedDashboardIds,
                          context.catalog.projects == currentCatalog.projects + [project],
                          projectOperations.allSatisfy({ $0.before.state == "absent" || $0.before == $0.after })
                    else { throw WorkspaceError.conflict }
                }
            } else {
                guard currentImage == catalogOperation.after,
                      currentCatalog.projects == context.catalog.projects,
                      currentCatalog.archivedDashboardIds == context.catalog.archivedDashboardIds else {
                    throw WorkspaceError.conflict
                }
            }
        }
    }

    private func validatePackageHead(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                                     context: Context, stagedBlobs: [String: Data]?,
                                     budget: WorkspaceReadBudget,
                                     requireCurrentBinding: Bool = true) throws {
        guard journal.kind == .packageHeadCommit else { return }
        try budget.check()
        guard let binding = journal.publication else { throw WorkspaceError.invalidSchema }
        if requireCurrentBinding {
            guard
              let project = context.catalog.projects.first(where: { $0.projectId == binding.projectId }),
              project.dashboardId == binding.dashboardId,
              let relative = project.location.path else { throw WorkspaceError.conflict }
        let folder = relative.split(separator: "/").map(String.init)
        let projectFD = try root.directory(folder); defer { close(projectFD) }
        let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
            from: root.read(projectFD, "screenpunk.project.json", readBudget: budget), shape: .project)
        try descriptor.validate(matching: project)
        let inventory = try root.inventory(folder, readBudget: budget,
            required: ["screenpunk.project.json", descriptor.screenConfig, descriptor.entry])
        var source: [String: Data] = [:]
        for member in inventory.includedFiles {
            try budget.check()
            let components = member.split(separator: "/").map(String.init)
            let parent = try root.directory(folder + Array(components.dropLast())); defer { close(parent) }
            source[member] = try root.read(parent, components.last!, maxBytes: 5 * 1024 * 1024,
                                           readBudget: budget)
        }
        guard try WorkbenchSourceHasher.hash(source) == binding.sourceVersion else {
            throw WorkspaceError.conflict
        }
        if descriptor.kind == "react" {
            guard let selected = binding.selectedToolchain,
                  selected.kitVersion == descriptor.kitVersion else { throw WorkspaceError.conflict }
            let toolchains = try root.directory(["Workbench", "Toolchains"]); defer { close(toolchains) }
            let requirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
                from: root.read(toolchains, "requirements.json", readBudget: budget), shape: .requirements)
            try requirements.validate()
            let matches = requirements.required.filter { $0.kitVersion == descriptor.kitVersion }
            guard matches.count == 1, matches[0] == selected else { throw WorkspaceError.conflict }
        } else if binding.selectedToolchain != nil { throw WorkspaceError.conflict }
        }

        guard let headOp = journal.operations.first(where: { $0.target.targetClass == "buildHead" }),
              let headHash = headOp.recoveryBlobHash else { throw WorkspaceError.invalidSchema }
        let headBytes = try stagedBlobs?[headHash] ?? readBlob(root, journal.transactionId, headHash)
        guard let raw = try JSONSerialization.jsonObject(with: headBytes) as? [String: Any],
              Set(raw.keys) == (binding.selectedToolchain == nil
                  ? ["schemaVersion", "projectID", "dashboardID", "sourceVersion", "revision", "digest"]
                  : ["schemaVersion", "projectID", "dashboardID", "sourceVersion", "revision", "digest", "selectedToolchain"])
        else { throw WorkspaceError.invalidSchema }
        let head = try JSONDecoder().decode(WorkbenchBuildHead.self, from: headBytes)
        guard head.schemaVersion == 1, head.projectID == binding.projectId,
              head.dashboardID == binding.dashboardId, head.sourceVersion == binding.sourceVersion,
              head.selectedToolchain == binding.selectedToolchain,
              WorkspaceValidation.id(head.revision), WorkspaceValidation.sha256(head.digest)
        else { throw WorkspaceError.conflict }
        let history = journal.operations.filter { $0.target.targetClass == "historyObject" }
        let objectID = WorkbenchTransactionDigest.hex(Data((head.dashboardID + "\0" + head.revision).utf8))
        guard history.allSatisfy({ $0.target.objectId == objectID }),
              let manifestOp = history.first(where: { $0.target.member == "manifest.json" }),
              let manifestHash = manifestOp.recoveryBlobHash else { throw WorkspaceError.conflict }
        let manifestBytes = try stagedBlobs?[manifestHash] ?? readBlob(root, journal.transactionId, manifestHash)
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestBytes)
        try PackageValidator.validate(manifest)
        guard manifest.dashboardId == head.dashboardID, manifest.revision == head.revision,
              manifest.digest == head.digest, try DeploymentDigest.digest(for: manifest) == head.digest,
              Set(history.compactMap(\.target.member)) ==
                Set(manifest.files.map { "files/" + $0.path }).union(["manifest.json"])
        else { throw WorkspaceError.conflict }
        for item in manifest.files {
            try budget.check()
            guard let operation = history.first(where: { $0.target.member == "files/" + item.path }),
                  operation.after.bytes == item.bytes, operation.after.sha256 == item.sha256,
                  let hash = operation.recoveryBlobHash else { throw WorkspaceError.conflict }
            let bytes = try stagedBlobs?[hash] ?? readBlob(root, journal.transactionId, hash)
            guard bytes.count == item.bytes, WorkbenchTransactionDigest.hex(bytes) == item.sha256 else {
                throw WorkspaceError.conflict
            }
        }
    }

    private func validateFinishedProjects(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                                          _ context: Context) throws {
        guard journal.kind == .projectEdit || journal.kind == .sourceCommit else { return }
        var seen = Set<String>()
        for index in journal.operations.indices {
            let target = journal.operations[index].target
            guard target.targetClass == "projectMember" else { continue }
            guard let id = target.projectId, seen.insert(id).inserted else { continue }
            let anchor: WorkspaceFiles
            if let external = context.roots[index] {
                // WorkspaceInventory uses a duplicated directory stream. Reopen an
                // external root for the post-commit scan so a prior scan's shared
                // directory offset cannot hide required members.
                let fresh = try WorkspaceFiles(path: external.path, requiredPrivateRoot: false)
                guard fresh.identity == external.identity else { throw WorkspaceError.conflict }
                anchor = fresh
            } else { anchor = root }
            let parts = Array(context.paths[index].dropLast(target.member!.split(separator: "/").count))
            let fd = try anchor.directory(parts); defer { close(fd) }
            let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self,
                from: anchor.read(fd, "screenpunk.project.json"), shape: .project)
            guard let project = context.catalog.projects.first(where: { $0.projectId == id }) else { throw WorkspaceError.conflict }
            try descriptor.validate(matching: project)
            let inventory = try anchor.inventory(parts, memberLimit: 2_000,
                required: ["screenpunk.project.json", descriptor.screenConfig, descriptor.entry])
            guard inventory.bytes <= 25 * 1024 * 1024 else { throw WorkspaceError.limitExceeded }
        }
    }

    private func validateHistoryQuotas(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                                       context: Context) throws {
        guard journal.kind == .historyPublish || journal.kind == .historyPrune ||
              journal.kind == .sourceCommit || journal.kind == .packageHeadCommit else { return }
        var seen = Set<String>()
        for index in journal.operations.indices {
            let target = journal.operations[index].target
            guard target.targetClass == "historyObject" else { continue }
            let key = "\(target.objectKind ?? ""):\(target.objectId ?? "")"
            guard seen.insert(key).inserted else { continue }
            let parts = Array(context.paths[index].dropLast(target.member!.split(separator: "/").count))
            let memberLimit = journal.kind == .sourceCommit && target.objectKind == "buildSource"
                ? 2_001 : 2_000
            let existing: WorkspaceProjectInventory
            if let fd = try parent(root, parts + [".inventory-probe"], create: false) {
                close(fd)
                existing = try root.inventory(parts, retained: true, memberLimit: memberLimit)
            } else { existing = WorkspaceProjectInventory() }
            var bytes = existing.bytes, members = existing.members
            var directories = existing.directories
            for affected in journal.operations.indices where journal.operations[affected].target.targetClass == "historyObject" &&
                journal.operations[affected].target.objectKind == target.objectKind &&
                journal.operations[affected].target.objectId == target.objectId {
                let operation = journal.operations[affected]
                let actual = try image(root, context.paths[affected])
                guard actual == operation.before || actual == operation.after else { throw WorkspaceError.conflict }
                if actual == operation.after { continue }
                bytes += Int64((operation.after.bytes ?? 0) - (actual.bytes ?? 0))
                if actual.state == "absent", operation.after.state == "present" {
                    members += 1
                    let memberParts = operation.target.member!.split(separator: "/").map(String.init)
                    for length in 1..<memberParts.count {
                        if directories.insert(memberParts.prefix(length).joined(separator: "/")).inserted {
                            members += 1
                        }
                    }
                } else if actual.state == "present", operation.after.state == "absent" {
                    members -= 1
                }
            }
            guard bytes >= 0, bytes <= 50 * 1024 * 1024,
                  members <= memberLimit else { throw WorkspaceError.limitExceeded }
        }
    }

    private func apply(_ root: WorkspaceFiles, _ selected: WorkspaceSelection,
                       _ journal: WorkbenchTransactionJournal) throws {
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + 120,
                                         cancelled: { false })
        let context = try loadContext(root, journal)
        guard context.roots.allSatisfy({ $0 == nil || $0!.identity.device == root.identity.device }) else {
            throw WorkspaceError.conflict
        }
        let initial = try descriptor(root).generation
        try validateImagesAndTargets(root, selected, journal, context: context,
                                     stagedBlobs: nil, budget: budget,
                                     requireCurrentPublicationBinding: initial == journal.expectedGeneration)
        if initial == journal.expectedGeneration + 1 {
            guard try allAfter(root, journal, context) else { throw WorkspaceError.conflict }
            try validateMetadataPostconditions(root, journal, context)
            try validateFinishedProjects(root, journal, context)
            try validateHistoryQuotas(root, journal, context: context)
            try checkpoint?(.beforeCleanup)
            try cleanup(root, journal)
            return
        }
        guard initial == journal.expectedGeneration else { throw WorkspaceError.conflict }
        try validatePlan(journal, selected, externalIDs: context.externalIDs)
        let work = try root.directory(transactionRoot + [journal.transactionId, "work"])
        defer { close(work) }
        let order = journal.operations.indices.sorted { a, b in
            if journal.kind == .packageHeadCommit {
                let aHead = journal.operations[a].target.targetClass == "buildHead"
                let bHead = journal.operations[b].target.targetClass == "buildHead"
                return aHead == bHead ? a < b : !aHead
            }
            if journal.kind == .sourceCommit {
                func rank(_ index: Int) -> Int {
                    switch journal.operations[index].target.targetClass {
                    case "historyObject": return 0
                    case "projectMember": return 1
                    case "portableMetadata": return journal.operations[index].target.object == "workspaceDescriptor" ? 3 : 2
                    default: return 4
                    }
                }
                return rank(a) == rank(b) ? a < b : rank(a) < rank(b)
            }
            let aDescriptor = journal.operations[a].target.object == "workspaceDescriptor"
            let bDescriptor = journal.operations[b].target.object == "workspaceDescriptor"
            return aDescriptor == bDescriptor ? a < b : !aDescriptor
        }
        for index in order {
            let op = journal.operations[index]
            // A source commit is contained under the held workspace lock. Its
            // complete target graph and source inventory were validated above;
            // every member still gets an immediate before-image observation and
            // no-follow write, followed by the complete postimage check below.
            // Re-decoding 4,004 targets and rescanning 2,000 files per member
            // would make the documented source limit unusable.
            let currentContext = journal.kind == .sourceCommit ? context : try loadContext(root, journal)
            try validatePlan(journal, selected, externalIDs: currentContext.externalIDs)
            if journal.kind == .projectEdit {
                try validateProjectPayloads(root, journal, context: currentContext, stagedBlobs: nil)
            }
            if journal.kind == .packageHeadCommit {
                try validatePackageHead(root, journal, context: currentContext,
                                        stagedBlobs: nil, budget: budget)
            }
            try verifySelection(root, selected)
            let anchor = currentContext.roots[index] ?? root
            let path = currentContext.paths[index]
            let observed = try observation(anchor, path)
            let current = observed.image
            guard current == op.before || current == op.after else { throw WorkspaceError.conflict }
            if op.target.object == "workspaceDescriptor" {
                try validateMetadataPostconditions(root, journal, currentContext)
            }
            if current != op.after {
                try checkpoint?(.beforeMemberMutation(index))
                try verifySelection(root, selected)
                try validatePlan(journal, selected, externalIDs: currentContext.externalIDs)
                if op.after.state == "present" {
                    let bytes = try readBlob(root, journal.transactionId, op.recoveryBlobHash!)
                    guard WorkbenchTransactionDigest.hex(bytes) == op.after.sha256,
                          bytes.count == op.after.bytes else { throw WorkspaceError.conflict }
                    let sameVolume = anchor.identity.device == root.identity.device
                    guard context.roots[index] == nil || sameVolume else { throw WorkspaceError.conflict }
                    try writeFile(anchor, path, bytes, expected: observed,
                                  stagedWork: sameVolume ? work : nil, stagedWorkRoot: sameVolume ? root : nil,
                                  stagedWorkPath: transactionRoot + [journal.transactionId, "work"],
                                  memberIndex: index)
                } else { try removeFile(anchor, path, expected: observed) }
                guard try image(anchor, path) == op.after else { throw WorkspaceError.conflict }
            }
            try checkpoint?(.memberPublished(index))
        }
        if !journal.operations.contains(where: { $0.target.object == "workspaceDescriptor" }) {
            try validatePlan(journal, selected, externalIDs: context.externalIDs)
            try verifySelection(root, selected)
            if journal.kind == .packageHeadCommit {
                try validatePackageHead(root, journal, context: context,
                                        stagedBlobs: nil, budget: budget)
            }
            guard try allAfter(root, journal, context), try descriptor(root).generation == journal.expectedGeneration else {
                throw WorkspaceError.conflict
            }
            try validateFinishedProjects(root, journal, context)
            try validateHistoryQuotas(root, journal, context: context)
            try verifySelection(root, selected)
            try validatePlan(journal, selected, externalIDs: context.externalIDs)
            try advanceGeneration(root, from: journal.expectedGeneration,
                                  stagedWork: work, transactionId: journal.transactionId,
                                  memberIndex: journal.operations.count)
        }
        guard try descriptor(root).generation == journal.expectedGeneration + 1,
              try allAfter(root, journal, context) else { throw WorkspaceError.conflict }
        try validateMetadataPostconditions(root, journal, context)
        try checkpoint?(.generationDurable)
        try checkpoint?(.beforeCleanup)
        try cleanup(root, journal)
    }

    private func allAfter(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal,
                          _ context: Context) throws -> Bool {
        for index in journal.operations.indices {
            if try image(context.roots[index] ?? root, context.paths[index]) != journal.operations[index].after { return false }
        }
        return true
    }
    private func advanceGeneration(_ root: WorkspaceFiles, from generation: Int,
                                   stagedWork: Int32, transactionId: String, memberIndex: Int) throws {
        let original = try root.read(root.fd, "workspace.json")
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              object["generation"] as? Int == generation else { throw WorkspaceError.conflict }
        object["generation"] = generation + 1
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let verified = try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: updated, shape: .descriptor)
        try verified.validate()
        let expected = try observation(root, ["workspace.json"])
        guard expected.image == .present(original) else { throw WorkspaceError.conflict }
        try writeFile(root, ["workspace.json"], updated, expected: expected,
                      stagedWork: stagedWork, stagedWorkRoot: root,
                      stagedWorkPath: transactionRoot + [transactionId, "work"], memberIndex: memberIndex)
    }

    private func readBlob(_ root: WorkspaceFiles, _ id: String, _ hash: String) throws -> Data {
        let dir = try root.directory(transactionRoot + [id, "blobs"]); defer { close(dir) }
        return try readRegular(dir, hash, max: maxPayload)
    }
    private struct Observed {
        let image: WorkbenchTransactionImage
        let node: WorkspaceNodeID?
    }
    private func image(_ root: WorkspaceFiles, _ parts: [String]) throws -> WorkbenchTransactionImage {
        try observation(root, parts).image
    }
    private func observation(_ root: WorkspaceFiles, _ parts: [String]) throws -> Observed {
        guard let parent = try parent(root, parts, create: false) else {
            return Observed(image: .absent, node: nil)
        }
        defer { close(parent) }
        return try observation(root, parent: parent, name: parts.last!)
    }
    private func observation(_ root: WorkspaceFiles, parent: Int32, name: String) throws -> Observed {
        guard try root.exists(parent, name) else { return Observed(image: .absent, node: nil) }
        let data = try readRegular(parent, name, max: maxPayload)
        let node = WorkspaceNodeID(try root.metadata(parent, name))
        return Observed(image: .present(data), node: node)
    }

    private func parent(_ root: WorkspaceFiles, _ parts: [String], create: Bool) throws -> Int32? {
        guard !parts.isEmpty, parts.count <= 32 else { throw WorkspaceError.invalidPath }
        var current = dup(root.fd)
        guard current >= 0 else { throw WorkspaceError.unavailable }
        do {
            var traversed = [String]()
            for name in parts.dropLast() {
                guard WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.invalidPath }
                let present = try collisionCheckedExists(current, name)
                if !present {
                    guard create else { close(current); return nil }
                    try root.verifyRoot()
                    guard try descriptorMatches(root, path: traversed, opened: current) else { throw WorkspaceError.conflict }
                    guard mkdirat(current, name, 0o700) == 0, fsync(current) == 0 else { throw WorkspaceError.unavailable }
                }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw WorkspaceError.unsafeFile }
                var info = stat()
                guard fstat(next, &info) == 0, info.st_uid == geteuid(),
                      info.st_dev == statDevice(root), info.st_mode & 0o022 == 0,
                      info.st_mode & 0o7000 == 0 else { close(next); throw WorkspaceError.unsafeFile }
                close(current); current = next
                traversed.append(name)
            }
            _ = try collisionCheckedExists(current, parts.last!)
            return current
        } catch { close(current); throw error }
    }
    private func node(_ fd: Int32) throws -> WorkspaceNodeID {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw WorkspaceError.unsafeFile }
        return WorkspaceNodeID(value)
    }
    private func descriptorMatches(_ root: WorkspaceFiles, path: [String], opened: Int32) throws -> Bool {
        let fresh = try root.directory(path); defer { close(fresh) }
        return try node(fresh) == node(opened)
    }
    private func parentAncestry(_ root: WorkspaceFiles, _ parts: [String]) throws -> [WorkspaceNodeID] {
        var result = [root.identity]
        var current = dup(root.fd)
        guard current >= 0 else { throw WorkspaceError.unavailable }
        defer { close(current) }
        for part in parts.dropLast() {
            guard WorkspaceValidation.member(part), !part.contains("/") else { throw WorkspaceError.invalidPath }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw WorkspaceError.conflict }
            do {
                var info = stat()
                guard fstat(next, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      info.st_uid == geteuid(), info.st_dev == statDevice(root),
                      info.st_mode & 0o022 == 0, info.st_mode & 0o7000 == 0 else {
                    throw WorkspaceError.unsafeFile
                }
                result.append(WorkspaceNodeID(info))
            } catch { close(next); throw error }
            close(current); current = next
        }
        return result
    }
    private func mutationGuard(_ root: WorkspaceFiles, _ parts: [String],
                               retainedParent: Int32, expected: Observed) throws -> WorkbenchMutationGuard {
        let ancestry = try parentAncestry(root, parts)
        guard ancestry.last == (try node(retainedParent)) else { throw WorkspaceError.conflict }
        return WorkbenchMutationGuard(ancestry: ancestry, image: expected.image, node: expected.node)
    }
    private func sameMutationObservation(_ root: WorkspaceFiles, _ parts: [String],
                                         retainedParent: Int32, guard binding: WorkbenchMutationGuard) throws -> Bool {
        try root.verifyRoot()
        let ancestry = try parentAncestry(root, parts)
        let leaf = try observation(root, parent: retainedParent, name: parts.last!)
        return binding.permits(currentAncestry: ancestry, retainedParent: try node(retainedParent),
                               currentImage: leaf.image, currentNode: leaf.node)
    }
    private func statDevice(_ root: WorkspaceFiles) -> dev_t { dev_t(root.identity.device) }
    private func collisionCheckedExists(_ directory: Int32, _ name: String) throws -> Bool {
        let key = WorkspaceValidation.portableKey(name)
        var exact = false
        for entry in try entries(directory) {
            if WorkspaceValidation.portableKey(entry) == key {
                guard entry == name else { throw WorkspaceError.conflict }
                exact = true
            }
        }
        return exact
    }
    private func entries(_ directory: Int32) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        rewinddir(stream) // dup shares the directory offset with its anchor descriptor.
        var names: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }; break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: item.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw WorkspaceError.unsafeFile }
            if name != "." && name != ".." { names.append(name) }
            guard names.count <= 1_000_000 else { throw WorkspaceError.limitExceeded }
        }
        return names
    }

    private func readRegular(_ directory: Int32, _ name: String, max: Int) throws -> Data {
        var before = stat()
        guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(),
              before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_mode & 0o7000 == 0, before.st_size >= 0, before.st_size <= max
        else { throw WorkspaceError.unsafeFile }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError.unsafeFile }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, WorkspaceNodeID(opened) == WorkspaceNodeID(before) else {
            throw WorkspaceError.conflict
        }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorkspaceError.unavailable }
            if count == 0 { break }
            guard output.count <= max - count else { throw WorkspaceError.limitExceeded }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == output.count,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              fstatat(directory, name, &opened, AT_SYMLINK_NOFOLLOW) == 0,
              WorkspaceNodeID(opened) == WorkspaceNodeID(before) else { throw WorkspaceError.conflict }
        return output
    }

    private func writeNew(_ directory: Int32, _ name: String, data: Data) throws {
        guard data.count <= maxPayload, WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.limitExceeded }
        guard try !collisionCheckedExists(directory, name) else { throw WorkspaceError.conflict }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WorkspaceError.conflict }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkspaceError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw WorkspaceError.unavailable }
    }
    private func writeFile(_ root: WorkspaceFiles, _ parts: [String], _ data: Data,
                           expected: Observed, stagedWork: Int32?, stagedWorkRoot: WorkspaceFiles?,
                           stagedWorkPath: [String], memberIndex: Int) throws {
        guard data.count <= maxPayload, let parent = try parent(root, parts, create: true) else { throw WorkspaceError.unavailable }
        defer { close(parent) }
        let name = parts.last!
        let binding = try mutationGuard(root, parts, retainedParent: parent, expected: expected)
        guard try sameMutationObservation(root, parts, retainedParent: parent, guard: binding) else {
            throw WorkspaceError.conflict
        }
        let source = stagedWork ?? parent
        if let stagedWork {
            guard let stagedWorkRoot, try descriptorMatches(stagedWorkRoot, path: stagedWorkPath, opened: stagedWork) else {
                throw WorkspaceError.conflict
            }
        }
        let temp = stagedWork == nil ? ".screenpunk-" + UUID().uuidString.lowercased() : String(memberIndex)
        if try collisionCheckedExists(source, temp) {
            guard stagedWork != nil, try readRegular(source, temp, max: maxPayload) == data else {
                throw WorkspaceError.conflict
            }
        } else { try writeNew(source, temp, data: data) }
        defer { if stagedWork == nil { _ = unlinkat(parent, temp, 0) } }
        try checkpoint?(.temporaryDurable(memberIndex))
        guard try sameMutationObservation(root, parts, retainedParent: parent, guard: binding) else {
            throw WorkspaceError.conflict
        }
        if let stagedWork {
            guard let stagedWorkRoot, try descriptorMatches(stagedWorkRoot, path: stagedWorkPath, opened: stagedWork) else {
                throw WorkspaceError.conflict
            }
        }
        let moved = expected.image.state == "absent"
            ? renameatx_np(source, temp, parent, name, UInt32(RENAME_EXCL))
            : renameat(source, temp, parent, name)
        guard moved == 0, fsync(parent) == 0 else { throw WorkspaceError.unavailable }
    }
    private func removeFile(_ root: WorkspaceFiles, _ parts: [String], expected: Observed) throws {
        guard expected.image.state == "present", let parent = try parent(root, parts, create: false) else { throw WorkspaceError.conflict }
        defer { close(parent) }
        let binding = try mutationGuard(root, parts, retainedParent: parent, expected: expected)
        guard try sameMutationObservation(root, parts, retainedParent: parent, guard: binding) else {
            throw WorkspaceError.conflict
        }
        guard unlinkat(parent, parts.last!, 0) == 0, fsync(parent) == 0 else { throw WorkspaceError.unavailable }
    }
    private func cleanup(_ root: WorkspaceFiles, _ journal: WorkbenchTransactionJournal) throws {
        let stage = try root.directory(transactionRoot + [journal.transactionId]); defer { close(stage) }
        let blobs = try root.directory(transactionRoot + [journal.transactionId, "blobs"]); defer { close(blobs) }
        let work = try root.directory(transactionRoot + [journal.transactionId, "work"]); defer { close(work) }
        let required = Set(journal.operations.compactMap(\.recoveryBlobHash))
        guard Set(try entries(stage)) == ["journal.json", "blobs", "work"],
              Set(try entries(blobs)) == required else { throw WorkspaceError.incomplete }
        try validateWork(root, journal)
        for hash in required {
            let value = try readRegular(blobs, hash, max: maxPayload)
            guard WorkbenchTransactionDigest.hex(value) == hash else { throw WorkspaceError.conflict }
        }
        // Retire the complete journal with one directory rename. An interruption
        // during later deletion leaves inert, recognizable data outside the replay
        // directory, never a half-deleted journal that recovery could misapply.
        let transactions = try root.directory(transactionRoot); defer { close(transactions) }
        let workbench = try root.directory(["Workbench"]); defer { close(workbench) }
        let retired = ".screenpunk-retired-" + journal.transactionId + "-" + UUID().uuidString.lowercased()
        guard try descriptorMatches(root, path: transactionRoot, opened: transactions),
              try descriptorMatches(root, path: ["Workbench"], opened: workbench),
              try descriptorMatches(root, path: transactionRoot + [journal.transactionId], opened: stage),
              try sameDirectoryNode(transactions, journal.transactionId, opened: stage),
              try sameDirectoryNode(stage, "blobs", opened: blobs),
              try sameDirectoryNode(stage, "work", opened: work) else { throw WorkspaceError.conflict }
        guard try !collisionCheckedExists(workbench, retired),
              renameat(transactions, journal.transactionId, workbench, retired) == 0,
              fsync(transactions) == 0, fsync(workbench) == 0 else { throw WorkspaceError.unavailable }
        guard try sameDirectoryNode(workbench, retired, opened: stage) else { throw WorkspaceError.conflict }
        guard try descriptorMatches(root, path: ["Workbench", retired], opened: stage) else { throw WorkspaceError.conflict }
        for hash in required { guard unlinkat(blobs, hash, 0) == 0 else { throw WorkspaceError.unavailable } }
        guard fsync(blobs) == 0, unlinkat(stage, "blobs", AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
        for name in try entries(work) { guard unlinkat(work, name, 0) == 0 else { throw WorkspaceError.unavailable } }
        guard fsync(work) == 0, unlinkat(stage, "work", AT_REMOVEDIR) == 0 else { throw WorkspaceError.unavailable }
        guard unlinkat(stage, "journal.json", 0) == 0, fsync(stage) == 0 else { throw WorkspaceError.unavailable }
        guard unlinkat(workbench, retired, AT_REMOVEDIR) == 0,
              fsync(workbench) == 0 else { throw WorkspaceError.unavailable }
    }
    private func sameDirectoryNode(_ parent: Int32, _ name: String, opened: Int32) throws -> Bool {
        var byName = stat(), byDescriptor = stat()
        guard fstatat(parent, name, &byName, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(opened, &byDescriptor) == 0,
              byName.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              byName.st_uid == geteuid(), byName.st_mode & 0o022 == 0,
              byName.st_mode & 0o7000 == 0 else { throw WorkspaceError.unsafeFile }
        return WorkspaceNodeID(byName) == WorkspaceNodeID(byDescriptor)
    }
}
#endif
