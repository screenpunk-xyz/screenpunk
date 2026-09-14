import CryptoKit
import Foundation
import ScreenpunkCore

public struct DashboardSummary: Sendable, Equatable {
    public var dashboardId: String
    public var name: String
    public var draftRevision: String
    public var revisionCount: Int
}

public struct DashboardRevisionRecord: Sendable, Equatable {
    public var manifest: DashboardManifest
    public var files: [String: Data]
    public var createdAt: Date
    public var packageDirectory: URL
    public init(manifest: DashboardManifest, files: [String: Data], createdAt: Date, packageDirectory: URL) {
        self.manifest = manifest; self.files = files; self.createdAt = createdAt; self.packageDirectory = packageDirectory
    }
}

public struct DashboardFileInput: Sendable, Equatable {
    public var path: String
    public var text: String?
    public var base64: String?

    public init(path: String, text: String? = nil, base64: String? = nil) {
        self.path = path
        self.text = text
        self.base64 = base64
    }

    public func bytes() throws -> Data {
        if let text {
            return Data(text.utf8)
        }
        if let base64, let data = Data(base64Encoded: base64) {
            return data
        }
        throw ControllerError.validationFailed(detail: "file \(path) missing text or base64")
    }
}

public enum DeploymentDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalJSON(_ manifest: DashboardManifest) throws -> Data {
        var copy = manifest
        copy.digest = nil
        copy.files.sort { $0.path < $1.path }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }

    public static func digest(for manifest: DashboardManifest) throws -> String {
        sha256Hex(try canonicalJSON(manifest))
    }
}

public struct MCPToolDescriptor: Sendable, Equatable {
    public var name: String
    public var group: String
    public var description: String
    public var readOnlyHint: Bool
    public var destructiveHint: Bool
    public var idempotentHint: Bool?
    public var openWorldHint: Bool
}

public struct MCPCatalogFile: Sendable, Equatable {
    public var previewLiveDefault: Bool
    public var helperStartsAutomatically: Bool
    public var workbenchMustBeVisible: Bool
    public var neverPathOnlyPreview: Bool
    public var neverPlaceholderImage: Bool
    public var errors: [String]
    public var tools: [MCPToolDescriptor]
}

public enum MCPCatalog: Sendable {
    public static func load() -> MCPCatalogFile {
        if let url = BundledResources.bundle.url(forResource: "mcp-catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return parse(json)
        }
        return fallbackCatalog()
    }

    public static func fallbackCatalog() -> MCPCatalogFile {
        MCPCatalogFile(
            previewLiveDefault: true,
            helperStartsAutomatically: true,
            workbenchMustBeVisible: false,
            neverPathOnlyPreview: true,
            neverPlaceholderImage: true,
            errors: ControllerErrorCode.allCases.map(\.rawValue),
            tools: [
                MCPToolDescriptor(
                    name: "preview_dashboard",
                    group: "preview",
                    description: "Render an exact dashboard revision on the hidden Screenpunk helper and return PNG image content plus metadata. Live preview — actions control your devices. Preview is live by default.",
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: nil,
                    openWorldHint: false
                ),
                MCPToolDescriptor(
                    name: "get_help",
                    group: "diagnostics",
                    description: "Troubleshooting help. Topic unlink explains the two-finger ten-second Unlink recovery gesture.",
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: nil,
                    openWorldHint: false
                )
            ]
        )
    }

    private static func parse(_ json: [String: Any]) -> MCPCatalogFile {
        let tools = (json["tools"] as? [[String: Any]] ?? []).compactMap { item -> MCPToolDescriptor? in
            guard let name = item["name"] as? String else { return nil }
            return MCPToolDescriptor(
                name: name,
                group: item["group"] as? String ?? "",
                description: item["description"] as? String ?? "",
                readOnlyHint: item["readOnlyHint"] as? Bool ?? false,
                destructiveHint: item["destructiveHint"] as? Bool ?? false,
                idempotentHint: item["idempotentHint"] as? Bool,
                openWorldHint: item["openWorldHint"] as? Bool ?? false
            )
        }
        return MCPCatalogFile(
            previewLiveDefault: json["previewLiveDefault"] as? Bool ?? true,
            helperStartsAutomatically: json["helperStartsAutomatically"] as? Bool ?? true,
            workbenchMustBeVisible: json["workbenchMustBeVisible"] as? Bool ?? false,
            neverPathOnlyPreview: json["neverPathOnlyPreview"] as? Bool ?? true,
            neverPlaceholderImage: json["neverPlaceholderImage"] as? Bool ?? true,
            errors: json["errors"] as? [String] ?? ControllerErrorCode.allCases.map(\.rawValue),
            tools: tools
        )
    }
}
