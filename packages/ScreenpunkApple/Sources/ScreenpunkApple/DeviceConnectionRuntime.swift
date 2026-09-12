import Foundation
import ScreenpunkCore

/// Factory for the on-device runtime. Devices call approved endpoints themselves.
public enum DeviceConnectionRuntime: Sendable {
    public static var macIsRuntimeProxy: Bool { ConnectionRuntime.macIsRuntimeProxy }
    public static var globalArbitraryLoads: Bool { TransportExceptions.globalArbitraryLoads }
    public static var followsRedirects: Bool { TransportExceptions.followsRedirects }
    public static var selfSignedHTTPSTrustedSilently: Bool {
        TransportExceptions.selfSignedHTTPSTrustedSilently
    }

    public static func make(
        dashboardId: String,
        store: any CredentialStore = KeychainCredentialStore(),
        httpBounds: HTTPAdapterBounds = .production,
        resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(),
        clock: any PairingClock = SystemClock()
    ) -> ConnectionRuntime {
        ConnectionRuntime(
            dashboardId: dashboardId,
            store: store,
            http: URLSessionHTTPTransport(bounds: httpBounds),
            webSocket: URLSessionWebSocketTransport(),
            resolver: resolver,
            clock: clock,
            httpBounds: httpBounds
        )
    }
}
