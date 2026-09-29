import Foundation

/// Optional package-owned capabilities. An empty object explicitly opts out.
public struct DeviceBehavior: Codable, Equatable, Sendable {
    public var temporaryActivation: TemporaryActivationConfiguration?
    public var audio: AudioPlaybackPermission?
    public init(temporaryActivation: TemporaryActivationConfiguration? = nil, audio: AudioPlaybackPermission? = nil) {
        self.temporaryActivation = temporaryActivation; self.audio = audio
    }
    public func validate() throws { try temporaryActivation?.validate() }
    public var allowsAudioAutoplay: Bool { audio?.autoplay == true }
}

public struct AudioPlaybackPermission: Codable, Equatable, Sendable {
    public var autoplay: Bool
    public init(autoplay: Bool) { self.autoplay = autoplay }
}

/// A bounded lease carried by one Home Assistant entity. Attribute names belong
/// to the screen, while lease ordering, dismissal and restoration belong to the host.
public struct TemporaryActivationConfiguration: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case homeAssistant }
    public var source: Source
    public var entityId: String
    public var activeState: String
    public var inactiveState: String
    public var idAttribute: String
    public var startedAtAttribute: String
    public var expiresAtAttribute: String
    public var maxDurationSeconds: Int

    public init(source: Source = .homeAssistant, entityId: String, activeState: String, inactiveState: String,
                idAttribute: String, startedAtAttribute: String, expiresAtAttribute: String, maxDurationSeconds: Int) {
        self.source = source; self.entityId = entityId; self.activeState = activeState; self.inactiveState = inactiveState
        self.idAttribute = idAttribute; self.startedAtAttribute = startedAtAttribute
        self.expiresAtAttribute = expiresAtAttribute; self.maxDurationSeconds = maxDurationSeconds
    }

    public func validate() throws {
        let attributes = [idAttribute, startedAtAttribute, expiresAtAttribute]
        guard entityId.utf8.count <= 255,
              entityId.range(of: "^[a-z0-9_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil,
              [activeState, inactiveState].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              activeState != inactiveState,
              attributes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil }),
              Set(attributes).count == attributes.count,
              (1...3600).contains(maxDurationSeconds) else { throw ConnectionFailure.validationFailed }
    }
}
