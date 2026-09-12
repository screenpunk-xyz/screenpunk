import Foundation

public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(dataBase64: String, mimeType: String, metadata: [String: String]?)

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    public func jsonObject() -> [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let data, let mime, let metadata):
            var object: [String: Any] = [
                "type": "image",
                "data": data,
                "mimeType": mime
            ]
            if let metadata {
                object["metadata"] = metadata
            }
            return object
        }
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public var content: [MCPContent]
    public var isError: Bool
    public var errorCode: String?

    public init(content: [MCPContent], isError: Bool = false, errorCode: String? = nil) {
        self.content = content
        self.isError = isError
        self.errorCode = errorCode
    }

    public static func text(_ text: String, error: ControllerError? = nil) -> MCPToolResult {
        MCPToolResult(
            content: [.text(text)],
            isError: error != nil,
            errorCode: error?.code.rawValue
        )
    }

    public static func failure(_ error: ControllerError) -> MCPToolResult {
        MCPToolResult(content: [.text(error.mcpText)], isError: true, errorCode: error.code.rawValue)
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "content": content.map { $0.jsonObject() },
            "isError": isError
        ]
        if let errorCode {
            object["errorCode"] = errorCode
        }
        return object
    }
}
