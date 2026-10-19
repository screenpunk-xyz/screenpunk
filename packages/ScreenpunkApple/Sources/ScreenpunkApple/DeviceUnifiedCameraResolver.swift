import Foundation
@_spi(ManagedRender) import ScreenpunkCore

struct DeviceUnifiedCameraResolver: CameraStreamResolver {
    let runtime: DeviceUnifiedManagedRuntime
    func resolveCamera(_ source: CameraSource, revision: String) async throws -> CameraStream {
        guard revision == runtime.content.revision else { throw ConnectionFailure.permissionRequired }
        let stream = try await runtime.resolveCamera(source)
        return CameraStream(url: stream.url, isAuthorized: stream.isAuthorized)
    }
}
