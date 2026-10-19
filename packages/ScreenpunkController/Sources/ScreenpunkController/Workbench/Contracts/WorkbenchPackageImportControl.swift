import Foundation
import CoreFoundation
import ScreenpunkCore
#if os(macOS)

public enum WorkbenchPackageImportMethod: String, CaseIterable, Sendable {
    case begin = "package.importBegin"
    case chunk = "package.importChunk"
    case status = "package.importStatus"
    case commit = "package.importCommit"
    case abort = "package.importAbort"
}

enum WorkbenchPackageImportRequest {
    case begin(String, Int, String, DashboardManifest, Int)
    case chunk(String, Int, String, Int, Int, Data)
    case status(String, Int, String)
    case commit(String, Int, String, String)
    case abort(String, Int, String)

    var method: WorkbenchPackageImportMethod {
        switch self {
        case .begin: return .begin
        case .chunk: return .chunk
        case .status: return .status
        case .commit: return .commit
        case .abort: return .abort
        }
    }

    static func parse(_ method: WorkbenchPackageImportMethod, _ params: [String: Any]) throws -> Self {
        let keys = Set(params.keys)
        guard let schema = params["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let workspaceId = params["expectedWorkspaceId"] as? String,
              WorkspaceValidation.id(workspaceId),
              let generation = number(params["expectedSelectionGeneration"]),
              (1...WorkspaceValidation.maxUInt).contains(generation) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let common: Set<String> = ["schemaVersion", "expectedWorkspaceId", "expectedSelectionGeneration"]
        switch method {
        case .begin:
            guard keys == common.union(["expectedDigest", "manifestBase64"]),
                  let digest = params["expectedDigest"] as? String,
                  WorkspaceValidation.sha256(digest),
                  let encoded = params["manifestBase64"] as? String,
                  encoded.utf8.count <= ((4 * 1024 * 1024 + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: encoded),
                  (1...4 * 1024 * 1024).contains(bytes.count),
                  bytes.base64EncodedString() == encoded,
                  let object = try? WorkbenchWireJSON.object(bytes, allowPackageManifest: true),
                  let manifest = try? JSONDecoder().decode(DashboardManifest.self, from: bytes),
                  let canonical = try? WorkbenchWireJSON.object(JSONEncoder().encode(manifest),
                    allowPackageManifest: true),
                  try JSONValue.from(object) == JSONValue.from(canonical),
                  manifest.digest == digest,
                  try DeploymentDigest.digest(for: manifest) == digest,
                  manifest.files.count < 2_000 else { throw WorkbenchIPCError(.invalidRequest) }
            do { try PackageValidator.validate(manifest) }
            catch { throw WorkbenchIPCError(.invalidRequest) }
            var total = bytes.count
            for file in manifest.files {
                guard file.bytes >= 0, file.bytes <= 50 * 1024 * 1024 - total else {
                    throw WorkbenchIPCError(.resourceLimit)
                }
                total += file.bytes
            }
            return .begin(workspaceId, generation, digest, manifest, bytes.count)
        case .chunk:
            guard keys == common.union(["uploadId", "fileIndex", "offset", "chunkSHA256", "bytesBase64"]),
                  let uploadId = params["uploadId"] as? String,
                  WorkspaceValidation.id(uploadId),
                  let fileIndex = number(params["fileIndex"]), (0..<2_000).contains(fileIndex),
                  let offset = number(params["offset"]), (0...50 * 1024 * 1024).contains(offset),
                  let hash = params["chunkSHA256"] as? String,
                  WorkspaceValidation.sha256(hash),
                  let encoded = params["bytesBase64"] as? String,
                  encoded.utf8.count <= ((64 * 1024 + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 64 * 1024,
                  bytes.base64EncodedString() == encoded,
                  DeploymentDigest.sha256Hex(bytes) == hash else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return .chunk(workspaceId, generation, uploadId, fileIndex, offset, bytes)
        case .status, .abort:
            guard keys == common.union(["uploadId"]),
                  let uploadId = params["uploadId"] as? String,
                  WorkspaceValidation.id(uploadId) else { throw WorkbenchIPCError(.invalidRequest) }
            return method == .status ? .status(workspaceId, generation, uploadId)
                                     : .abort(workspaceId, generation, uploadId)
        case .commit:
            guard keys == common.union(["uploadId", "expectedDigest"]),
                  let uploadId = params["uploadId"] as? String,
                  WorkspaceValidation.id(uploadId),
                  let digest = params["expectedDigest"] as? String,
                  WorkspaceValidation.sha256(digest) else { throw WorkbenchIPCError(.invalidRequest) }
            return .commit(workspaceId, generation, uploadId, digest)
        }
    }
    private static func number(_ any: Any?) -> Int? {
        guard let value = any as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue == Double(value.intValue) else { return nil }
        return value.intValue
    }
}

public struct WorkbenchPackageImportResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let uploadId: String?
    public let nextFileIndex: Int?
    public let nextOffset: Int?
    public let receipt: WorkbenchBoundedPackageImportReceipt?
    public let aborted: Bool?

    init(kind: String, uploadId: String? = nil, nextFileIndex: Int? = nil,
         nextOffset: Int? = nil, receipt: WorkbenchBoundedPackageImportReceipt? = nil,
         aborted: Bool? = nil) {
        schemaVersion = 1; self.kind = kind; self.uploadId = uploadId
        self.nextFileIndex = nextFileIndex; self.nextOffset = nextOffset
        self.receipt = receipt; self.aborted = aborted
    }
    func validate(for method: WorkbenchPackageImportMethod) throws {
        guard schemaVersion == 1, kind == method.rawValue else { throw WorkbenchIPCError(.invalidRequest) }
        switch method {
        case .begin, .chunk, .status:
            guard let uploadId, WorkspaceValidation.id(uploadId),
                  let nextFileIndex, (0...2_000).contains(nextFileIndex),
                  let nextOffset, (0...50 * 1024 * 1024).contains(nextOffset),
                  receipt == nil, aborted == nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .commit:
            guard uploadId == nil, nextFileIndex == nil, nextOffset == nil,
                  receipt != nil, aborted == nil else { throw WorkbenchIPCError(.invalidRequest) }
        case .abort:
            guard uploadId == nil, nextFileIndex == nil, nextOffset == nil,
                  receipt == nil, aborted == true else { throw WorkbenchIPCError(.invalidRequest) }
        }
    }
}
#endif
