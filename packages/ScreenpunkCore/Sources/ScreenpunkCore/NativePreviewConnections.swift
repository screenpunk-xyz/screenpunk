import Foundation

public struct NativePreviewConnections: Codable, Sendable {
    public var homeAssistant: HomeAssistantProvisioning?
    public var publicReads: PublicReadProvisioning?
    public init(homeAssistant: HomeAssistantProvisioning? = nil, publicReads: PublicReadProvisioning? = nil) {
        self.homeAssistant = homeAssistant; self.publicReads = publicReads
    }
}
