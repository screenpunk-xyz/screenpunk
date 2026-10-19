import Foundation
import CoreFoundation
import ScreenpunkCore
import ScreenpunkController

final class PackageImportManifestRegistry {
    private struct Entry {
        let uploadId: String
        let manifest: DashboardManifest
        let deadline: TimeInterval
        var expiresAt: TimeInterval
    }
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var entry: Entry?
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    func canBegin() throws {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard entry == nil else { throw WorkbenchIPCError(.workspaceConflict) }
    }
    func store(_ manifest: DashboardManifest, uploadId: String) throws {
        guard WorkspaceValidation.id(uploadId),
              try JSONEncoder().encode(manifest).count <= 4 * 1024 * 1024 else {
            throw WorkbenchIPCError(.resourceLimit)
        }
        lock.lock(); defer { lock.unlock() }
        expire()
        guard entry == nil else { throw WorkbenchIPCError(.workspaceConflict) }
        let started = now()
        entry = .init(uploadId: uploadId, manifest: manifest,
            deadline: started + 600, expiresAt: started + 120)
    }
    func load(_ uploadId: String) -> DashboardManifest? {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard entry?.uploadId == uploadId else { return nil }
        return entry?.manifest
    }
    func renew(_ uploadId: String) throws {
        lock.lock(); defer { lock.unlock() }
        expire()
        guard var current = entry, current.uploadId == uploadId else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        current.expiresAt = min(now() + 120, current.deadline)
        entry = current
    }
    func remove(_ uploadId: String) {
        lock.lock(); defer { lock.unlock() }
        if entry?.uploadId == uploadId { entry = nil }
    }
    private func expire() {
        if let current = entry, now() >= current.expiresAt { entry = nil }
    }
}

extension LegacyBrokerAdapter {
    enum PackageImportInput {
        case begin(DashboardManifest, String)
        case chunk(String, Int, Int, Data)
        case status(String)
        case commit(String, String)
        case abort(String)
    }

    func packageImportCall(name: String, arguments: [String: Any],
                           submission: LegacyMutationSubmission) throws -> (String, Bool) {
        let selected = try client.workspaceStatus()
        guard selected.state == "selected", let workspaceId = selected.workspaceId,
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let input = try Self.packageImportInput(name: name, arguments: arguments,
            workspaceId: workspaceId, generation: generation)
        let value: String
        switch input {
        case .begin(let manifest, let digest):
            try packageImportRegistry.canBegin()
            let result = try submission.send {
                try client.beginPackageImport(manifest: manifest,
                    expectedDigest: digest, expectedWorkspaceId: workspaceId,
                    expectedSelectionGeneration: generation)
            }
            try Self.validateImportProgress(result, method: .begin, expectedUploadId: nil)
            guard result.nextFileIndex == 0, result.nextOffset == 0 else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try packageImportRegistry.store(manifest, uploadId: result.uploadId!)
            value = try Self.json(result)
        case .chunk(let uploadId, let fileIndex, let offset, let bytes):
            guard let manifest = packageImportRegistry.load(uploadId) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let result = try submission.send {
                try client.sendPackageImportChunk(uploadId: uploadId,
                    fileIndex: fileIndex, offset: offset, bytes: bytes,
                    expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
            }
            try Self.validateImportProgress(result, method: .chunk,
                expectedUploadId: uploadId, manifest: manifest,
                sent: (fileIndex, offset, bytes.count))
            try packageImportRegistry.renew(uploadId)
            value = try Self.json(result)
        case .status(let uploadId):
            guard let manifest = packageImportRegistry.load(uploadId) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let result = try client.packageImportStatus(uploadId: uploadId,
                expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
            try Self.validateImportProgress(result, method: .status,
                expectedUploadId: uploadId, manifest: manifest)
            value = try Self.json(result)
        case .commit(let uploadId, let digest):
            guard packageImportRegistry.load(uploadId) != nil else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let receipt = try submission.send {
                try client.commitPackageImport(uploadId: uploadId,
                    expectedDigest: digest, expectedWorkspaceId: workspaceId,
                    expectedSelectionGeneration: generation)
            }
            try Self.validateImportReceipt(receipt, digest: digest,
                workspaceId: workspaceId, generation: generation)
            packageImportRegistry.remove(uploadId)
            value = try Self.json(receipt)
        case .abort(let uploadId):
            try submission.send {
                try client.abortPackageImport(uploadId: uploadId,
                    expectedWorkspaceId: workspaceId,
                    expectedSelectionGeneration: generation)
            }
            packageImportRegistry.remove(uploadId)
            value = "{\"aborted\":true}"
        }
        // Mutating calls already bind the expected selection at broker admission.
        // A second read after an acknowledged commit could fail or observe a
        // later selection and falsely report that the applied import failed.
        if case .status = input {
            let current = try client.workspaceStatus()
            guard current.workspaceId == workspaceId,
                  current.selectionGeneration == generation else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
        }
        return (value, false)
    }

    static func validateImportProgress(_ result: WorkbenchPackageImportResult,
                                       method: WorkbenchPackageImportMethod,
                                       expectedUploadId: String?,
                                       manifest: DashboardManifest? = nil,
                                       sent: (fileIndex: Int, offset: Int, byteCount: Int)? = nil) throws {
        guard result.schemaVersion == 1, result.kind == method.rawValue,
              result.receipt == nil, result.aborted == nil,
              let uploadId = result.uploadId, WorkspaceValidation.id(uploadId),
              expectedUploadId == nil || uploadId == expectedUploadId,
              let nextFile = result.nextFileIndex, (0...2_000).contains(nextFile),
              let nextOffset = result.nextOffset, (0...50 * 1024 * 1024).contains(nextOffset) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        if let sent {
            let (end, overflow) = sent.offset.addingReportingOverflow(sent.byteCount)
            guard method == .chunk, let manifest, !overflow,
                  manifest.files.indices.contains(sent.fileIndex),
                  sent.offset >= 0, end <= manifest.files[sent.fileIndex].bytes,
                  (nextFile == sent.fileIndex && nextOffset == end &&
                    end < manifest.files[sent.fileIndex].bytes ||
                   nextFile == sent.fileIndex + 1 && nextOffset == 0 &&
                    end == manifest.files[sent.fileIndex].bytes) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        if let manifest {
            guard nextFile <= manifest.files.count,
                  (nextFile == manifest.files.count && nextOffset == 0 ||
                   nextFile < manifest.files.count &&
                    nextOffset <= manifest.files[nextFile].bytes) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
    }

    static func validateImportReceipt(_ receipt: WorkbenchBoundedPackageImportReceipt,
                                      digest: String, workspaceId: String,
                                      generation: Int) throws {
        guard receipt.schemaVersion == 1, receipt.workspaceId == workspaceId,
              receipt.selectionGeneration == generation, receipt.digest == digest,
              receipt.storage == "workspace-history",
              receipt.provenance == "imported-package-untrusted",
              receipt.editableSourceIncluded == false,
              receipt.localBindingsImported == false,
              receipt.deploymentAuthority == "none",
              (0..<2_000).contains(receipt.fileCount),
              (0...50 * 1024 * 1024).contains(receipt.includedBytes) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }

    static func packageImportInput(name: String, arguments: [String: Any],
                                   workspaceId: String, generation: Int) throws -> PackageImportInput {
        let common: Set<String> = ["expectedWorkspaceId", "expectedSelectionGeneration"]
        let specific: Set<String>
        switch name {
        case "begin_workspace_package_import": specific = ["expectedDigest", "manifestBase64"]
        case "send_workspace_package_import_chunk":
            specific = ["uploadId", "fileIndex", "offset", "chunkSHA256", "bytesBase64"]
        case "get_workspace_package_import_status", "abort_workspace_package_import":
            specific = ["uploadId"]
        case "commit_workspace_package_import": specific = ["uploadId", "expectedDigest"]
        default: throw WorkbenchIPCError(.methodNotFound)
        }
        guard Set(arguments.keys) == common.union(specific) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        guard arguments["expectedWorkspaceId"] as? String == workspaceId,
              let claimed = integer(arguments["expectedSelectionGeneration"]),
              claimed == generation else { throw WorkbenchIPCError(.workspaceConflict) }
        switch name {
        case "begin_workspace_package_import":
            guard let digest = arguments["expectedDigest"] as? String,
                  WorkspaceValidation.sha256(digest),
                  let encoded = arguments["manifestBase64"] as? String,
                  encoded.utf8.count <= ((4 * 1024 * 1024 + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: encoded),
                  (1...4 * 1024 * 1024).contains(bytes.count),
                  bytes.base64EncodedString() == encoded,
                  let raw = try? JSONSerialization.jsonObject(with: bytes),
                  let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: bytes),
                  let canonical = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)),
                  (try? JSONValue.from(raw)) == (try? JSONValue.from(canonical)),
                  manifest.digest == digest,
                  (try? DeploymentDigest.digest(for: manifest)) == digest else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try PackageValidator.validate(manifest)
            return .begin(manifest, digest)
        case "send_workspace_package_import_chunk":
            guard let uploadId = arguments["uploadId"] as? String,
                  WorkspaceValidation.id(uploadId),
                  let fileIndex = integer(arguments["fileIndex"]), (0..<2_000).contains(fileIndex),
                  let offset = integer(arguments["offset"]), (0...50 * 1024 * 1024).contains(offset),
                  let hash = arguments["chunkSHA256"] as? String,
                  WorkspaceValidation.sha256(hash),
                  let encoded = arguments["bytesBase64"] as? String,
                  encoded.utf8.count <= ((64 * 1024 + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 64 * 1024,
                  bytes.base64EncodedString() == encoded,
                  DeploymentDigest.sha256Hex(bytes) == hash else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .chunk(uploadId, fileIndex, offset, bytes)
        case "get_workspace_package_import_status", "abort_workspace_package_import":
            guard let uploadId = arguments["uploadId"] as? String,
                  WorkspaceValidation.id(uploadId) else { throw WorkbenchIPCError(.invalidRequest) }
            return name == "get_workspace_package_import_status" ? .status(uploadId) : .abort(uploadId)
        case "commit_workspace_package_import":
            guard let uploadId = arguments["uploadId"] as? String,
                  WorkspaceValidation.id(uploadId),
                  let digest = arguments["expectedDigest"] as? String,
                  WorkspaceValidation.sha256(digest) else { throw WorkbenchIPCError(.invalidRequest) }
            return .commit(uploadId, digest)
        default: throw WorkbenchIPCError(.methodNotFound)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    static func packageImportSchema(_ name: String) -> JSONValue {
        func string() -> JSONValue { .object(["type": .string("string")]) }
        func integer(minimum: Int, maximum: Int) -> JSONValue {
            .object(["type": .string("integer"), "minimum": .int(minimum), "maximum": .int(maximum)])
        }
        let digest: JSONValue = .object(["type": .string("string"),
            "pattern": .string("^[0-9a-f]{64}$")])
        let base64Pattern = JSONValue.string("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
        var fields: [String: JSONValue] = ["expectedWorkspaceId": string(),
            "expectedSelectionGeneration": integer(minimum: 1, maximum: WorkspaceValidation.maxUInt)]
        var required = ["expectedWorkspaceId", "expectedSelectionGeneration"]
        switch name {
        case "begin_workspace_package_import":
            fields["expectedDigest"] = digest
            fields["manifestBase64"] = .object(["type": .string("string"),
                "maxLength": .int(((4 * 1024 * 1024 + 2) / 3) * 4),
                "contentEncoding": .string("base64"), "pattern": base64Pattern])
            required += ["expectedDigest", "manifestBase64"]
        case "send_workspace_package_import_chunk":
            fields["uploadId"] = string()
            fields["fileIndex"] = integer(minimum: 0, maximum: 1_999)
            fields["offset"] = integer(minimum: 0, maximum: 50 * 1024 * 1024)
            fields["chunkSHA256"] = digest
            fields["bytesBase64"] = .object(["type": .string("string"),
                "maxLength": .int(((64 * 1024 + 2) / 3) * 4),
                "contentEncoding": .string("base64"), "pattern": base64Pattern])
            required += ["uploadId", "fileIndex", "offset", "chunkSHA256", "bytesBase64"]
        case "commit_workspace_package_import":
            fields["uploadId"] = string(); fields["expectedDigest"] = digest
            required += ["uploadId", "expectedDigest"]
        default:
            fields["uploadId"] = string(); required.append("uploadId")
        }
        return .object(["type": .string("object"), "properties": .object(fields),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)])
    }
}
