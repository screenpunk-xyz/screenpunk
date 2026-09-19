import Foundation

/// A screen identifies a source, never a URL or credential. Native resolvers can
/// add direct-camera connections without changing the rendering/session contract.
public struct CameraSource: Codable, Sendable, Equatable {
    public let kind: String
    public let connection: String
    public let entityId: String
    public init(kind: String = "homeAssistant", connection: String = "home", entityId: String) {
        self.kind = kind; self.connection = connection; self.entityId = entityId
    }
    public static func validateEntities(_ entities: [String]) throws {
        guard entities.count <= 16, Set(entities).count == entities.count,
              entities.allSatisfy({ $0.utf8.count <= 255 && $0.range(of: "^camera\\.[a-z0-9_]+$", options: .regularExpression) != nil }) else {
            throw ConnectionFailure.validationFailed
        }
    }
}
