import Foundation

#if os(macOS)
public enum WorkbenchScreenMutationMethod: String, CaseIterable, Sendable {
    case sourceRename = "screen.sourceRename"
    case packageRename = "screen.packageRename"
    case packageDuplicate = "screen.packageDuplicate"
    case packageOrientation = "screen.packageOrientation"
    case iconSet = "screen.iconSet"
    case archive = "screen.archive"
    case reactSourceAssociate = "screen.reactSourceAssociate"
}

enum WorkbenchScreenMutationRequest {
    case sourceRename(WorkbenchScreenRenameRequest)
    case packageRename(WorkbenchScreenPackageRenameRequest)
    case packageDuplicate(WorkbenchScreenPackageDuplicateRequest)
    case packageOrientation(WorkbenchScreenPackageOrientationRequest)
    case iconSet(WorkbenchScreenIconRequest)
    case archive(WorkbenchScreenArchiveRequest)
    case reactSourceAssociate(WorkbenchReactSourceAssociationRequest)

    static func parse(_ method: WorkbenchScreenMutationMethod, _ fields: [String: Any]) throws -> Self {
        do {
            switch method {
            case .sourceRename: return .sourceRename(try .parse(fields))
            case .packageRename: return .packageRename(try .parse(fields))
            case .packageDuplicate: return .packageDuplicate(try .parse(fields))
            case .packageOrientation: return .packageOrientation(try .parse(fields))
            case .iconSet: return .iconSet(try .parse(fields))
            case .archive: return .archive(try .parse(fields))
            case .reactSourceAssociate: return .reactSourceAssociate(try .parse(fields))
            }
        } catch { throw WorkbenchIPCError(.invalidRequest) }
    }

    var method: WorkbenchScreenMutationMethod {
        switch self {
        case .sourceRename: return .sourceRename
        case .packageRename: return .packageRename
        case .packageDuplicate: return .packageDuplicate
        case .packageOrientation: return .packageOrientation
        case .iconSet: return .iconSet
        case .archive: return .archive
        case .reactSourceAssociate: return .reactSourceAssociate
        }
    }
}

enum WorkbenchScreenMutationResult: Codable {
    case sourceRename(WorkbenchScreenRenameResult)
    case packageRename(WorkbenchScreenPackageRenameResult)
    case packageDuplicate(WorkbenchScreenPackageDuplicateResult)
    case packageOrientation(WorkbenchScreenPackageOrientationResult)
    case iconSet(WorkbenchScreenIconResult)
    case archive(WorkbenchScreenArchiveResult)
    case reactSourceAssociate(WorkbenchReactSourceAssociationResult)

    private enum CodingKeys: String, CodingKey { case schemaVersion, kind, value }

    var method: WorkbenchScreenMutationMethod {
        switch self {
        case .sourceRename: return .sourceRename
        case .packageRename: return .packageRename
        case .packageDuplicate: return .packageDuplicate
        case .packageOrientation: return .packageOrientation
        case .iconSet: return .iconSet
        case .archive: return .archive
        case .reactSourceAssociate: return .reactSourceAssociate
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(c.allKeys) == [.schemaVersion, .kind, .value],
              try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        switch try c.decode(WorkbenchScreenMutationMethod.self, forKey: .kind) {
        case .sourceRename: self = .sourceRename(try c.decode(WorkbenchScreenRenameResult.self, forKey: .value))
        case .packageRename: self = .packageRename(try c.decode(WorkbenchScreenPackageRenameResult.self, forKey: .value))
        case .packageDuplicate: self = .packageDuplicate(try c.decode(WorkbenchScreenPackageDuplicateResult.self, forKey: .value))
        case .packageOrientation: self = .packageOrientation(try c.decode(WorkbenchScreenPackageOrientationResult.self, forKey: .value))
        case .iconSet: self = .iconSet(try c.decode(WorkbenchScreenIconResult.self, forKey: .value))
        case .archive: self = .archive(try c.decode(WorkbenchScreenArchiveResult.self, forKey: .value))
        case .reactSourceAssociate:
            self = .reactSourceAssociate(try c.decode(WorkbenchReactSourceAssociationResult.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion)
        try c.encode(method, forKey: .kind)
        switch self {
        case .sourceRename(let value): try c.encode(value, forKey: .value)
        case .packageRename(let value): try c.encode(value, forKey: .value)
        case .packageDuplicate(let value): try c.encode(value, forKey: .value)
        case .packageOrientation(let value): try c.encode(value, forKey: .value)
        case .iconSet(let value): try c.encode(value, forKey: .value)
        case .archive(let value): try c.encode(value, forKey: .value)
        case .reactSourceAssociate(let value): try c.encode(value, forKey: .value)
        }
    }

    func validate(for request: WorkbenchScreenMutationRequest) throws {
        guard method == request.method else { throw WorkbenchIPCError(.invalidRequest) }
        switch (self, request) {
        case (.sourceRename(let value), .sourceRename(let input)):
            guard value.workspaceId == input.expectedWorkspaceId,
                  value.selectionGeneration == input.expectedSelectionGeneration,
                  value.catalogGeneration >= input.expectedCatalogGeneration,
                  value.catalogGeneration <= input.expectedCatalogGeneration + 1,
                  value.project.project.projectId == input.projectId else { throw WorkbenchIPCError(.invalidRequest) }
        case (.packageRename(let value), .packageRename(let input)):
            guard value.workspaceId == input.expectedWorkspaceId,
                  value.selectionGeneration == input.expectedSelectionGeneration,
                  value.catalogGeneration >= input.expectedCatalogGeneration,
                  value.catalogGeneration <= input.expectedCatalogGeneration + 1,
                  value.dashboardId == input.dashboardId,
                  value.priorRevision == input.expectedRevision,
                  WorkspaceValidation.sha256(value.digest) else { throw WorkbenchIPCError(.invalidRequest) }
        case (.packageDuplicate(let value), .packageDuplicate(let input)):
            guard value.workspaceId == input.source.expectedWorkspaceId,
                  value.selectionGeneration == input.source.expectedSelectionGeneration,
                  value.catalogGeneration == input.source.expectedCatalogGeneration + 1,
                  value.sourceDashboardId == input.source.dashboardId,
                  value.sourceRevision == input.source.expectedRevision,
                  WorkspaceValidation.id(value.dashboardId),
                  WorkspaceValidation.sha256(value.digest) else { throw WorkbenchIPCError(.invalidRequest) }
        case (.packageOrientation(let value), .packageOrientation(let input)):
            guard value.workspaceId == input.expectedWorkspaceId,
                  value.selectionGeneration == input.expectedSelectionGeneration,
                  value.catalogGeneration >= input.expectedCatalogGeneration,
                  value.catalogGeneration <= input.expectedCatalogGeneration + 1,
                  value.dashboardId == input.dashboardId,
                  value.priorRevision == input.expectedRevision,
                  value.support == input.support,
                  WorkspaceValidation.sha256(value.digest) else { throw WorkbenchIPCError(.invalidRequest) }
        case (.iconSet(let value), .iconSet(let input)):
            guard value.workspaceId == input.expectedWorkspaceId,
                  value.selectionGeneration == input.expectedSelectionGeneration,
                  value.catalogGeneration >= input.expectedCatalogGeneration,
                  value.catalogGeneration <= input.expectedCatalogGeneration + 1,
                  value.dashboardId == input.dashboardId,
                  value.symbol == input.symbol else { throw WorkbenchIPCError(.invalidRequest) }
        case (.archive(let value), .archive(let input)):
            guard value.workspaceId == input.expectedWorkspaceId,
                  value.selectionGeneration == input.expectedSelectionGeneration,
                  value.catalogGeneration == input.expectedCatalogGeneration + 1,
                  value.dashboardId == input.dashboardId,
                  value.packageHistoryRetained, value.deviceContentsUntouched else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        case (.reactSourceAssociate(let value), .reactSourceAssociate(let input)):
            guard value.workspaceId == input.expectedWorkspaceId,
                  value.selectionGeneration == input.expectedSelectionGeneration,
                  value.catalogGeneration >= input.expectedCatalogGeneration,
                  value.catalogGeneration <= input.expectedCatalogGeneration + 1,
                  value.project.project.projectId == input.projectId,
                  value.project.project.dashboardId == input.dashboardId,
                  value.packageRevision == input.expectedRevision,
                  value.packageDigest == input.expectedDigest,
                  !value.authorityRestored else { throw WorkbenchIPCError(.invalidRequest) }
        default: throw WorkbenchIPCError(.invalidRequest)
        }
    }

    func validateWireShape(_ object: [String: Any]) throws {
        guard Set(object.keys) == ["schemaVersion", "kind", "value"],
              let value = object["value"] as? [String: Any] else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let expected: Set<String>
        switch method {
        case .sourceRename, .reactSourceAssociate:
            expected = Set(["workspaceId", "selectionGeneration", "catalogGeneration", "project"])
                .union(method == .reactSourceAssociate
                    ? ["packageRevision", "packageDigest", "authorityRestored"] : [])
            guard let source = value["project"] as? [String: Any],
                  Set(source.keys) == ["project", "path", "sourceVersion", "sourceHashVersion",
                                       "fileCount", "includedBytes"],
                  let project = source["project"] as? [String: Any],
                  Set(project.keys) == ["projectId", "dashboardId", "name", "location",
                                        "collectionIds", "sortOrder"],
                  let location = project["location"] as? [String: Any],
                  Set(location.keys) == ["kind", "path"],
                  location["kind"] as? String == "workspace" else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        case .packageRename:
            expected = ["workspaceId", "selectionGeneration", "catalogGeneration",
                        "dashboardId", "priorRevision", "revision", "digest", "name"]
        case .packageDuplicate:
            expected = ["workspaceId", "selectionGeneration", "catalogGeneration",
                        "sourceDashboardId", "sourceRevision", "dashboardId", "revision",
                        "digest", "name"]
        case .packageOrientation:
            expected = ["workspaceId", "selectionGeneration", "catalogGeneration",
                        "dashboardId", "priorRevision", "revision", "digest", "support"]
        case .iconSet:
            expected = ["workspaceId", "selectionGeneration", "catalogGeneration",
                        "dashboardId", "symbol"]
        case .archive:
            expected = ["workspaceId", "selectionGeneration", "catalogGeneration",
                        "dashboardId", "sourceRetained", "packageHistoryRetained",
                        "deviceContentsUntouched"]
        }
        guard Set(value.keys) == expected else { throw WorkbenchIPCError(.invalidRequest) }
    }
}

extension WorkbenchScreenMutationMethod: Codable {}
#endif
