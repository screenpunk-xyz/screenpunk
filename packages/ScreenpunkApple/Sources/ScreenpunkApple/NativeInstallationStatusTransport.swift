import Foundation
@_spi(NativeInstallation) import ScreenpunkCore

/// Fixed transport orchestration. Only the original Core HTTPS task can mint its IO observation.
public final class NativeInstallationStatusTransport: @unchecked Sendable {
    private let origin: URL
    public init(origin: URL) throws { self.origin = try NativeOperationalInstallation.validatedOrigin(origin) }
    @_spi(NativeInstallation) public func send(_ request: NativeOperationalStatusRequest, authority: DeviceManagementAuthority,
        context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeOperationalStatusObservation {
        try Task.checkCancellation(); try request.requireOrigin(origin)
        try authority.beginCloudStatusRequest(context, requestID: request.requestID)
        let observation = try await request.performFixedTransport(origin: origin)
        try Task.checkCancellation()
        try authority.acceptCloudStatus(observation, context: context)
        return observation
    }
    @_spi(NativeInstallation) public func reportState(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority,
        context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryStateHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let result = try await NativeDeliveryStateHTTPObservation.collect(body: body, installation: installation, current: current, origin: origin)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context)
        return result
    }
    @_spi(NativeInstallation) public func command(installation: NativeOperationalInstallation, current: NativeCurrentInstallationDispatch,
        authority: DeviceManagementAuthority, context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryCommandHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let result = try await NativeDeliveryCommandHTTPObservation.collect(installation: installation, current: current, origin: origin)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return result
    }
    @_spi(NativeInstallation) public func plan(_ command: NativeDeliveryCommandHTTPObservation, nativeOperationID: UUID,
        current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority,
        context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryPlanHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let result = try await command.fetchPlan(current: current, origin: origin, nativeOperationID: nativeOperationID)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return result
    }
    @_spi(NativeInstallation) public func archives(_ plan: NativeDeliveryPlanHTTPObservation, current: NativeCurrentInstallationDispatch,
        target: DeviceProfile, profileID: String, revisionName: String, authority: DeviceManagementAuthority,
        context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryArchiveHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let result = try await plan.fetchArchives(current: current, origin: origin, target: target, profileID: profileID, revisionName: revisionName)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return result
    }
    @_spi(NativeInstallation) public func activate(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation,
        current: NativeCurrentInstallationDispatch, authority: DeviceManagementAuthority,
        context: DeviceManagementAuthority.CloudInstallationContext) async throws -> NativeDeliveryActivationHTTPObservation {
        try authority.validateCloudRequestStart(context)
        let result = try await NativeDeliveryActivationHTTPObservation.collect(body: body, installation: installation, current: current, origin: origin)
        try Task.checkCancellation(); try authority.validateCloudRequestStart(context); return result
    }
    @_spi(NativeInstallation) public func receipt(_ body: NativeDeliveryDurableBody, installation: NativeOperationalInstallation) async throws -> NativeDeliveryReceiptHTTPObservation {
        // Reporting uses retained original owner context, not a revived dispatch lease.
        try await NativeDeliveryReceiptHTTPObservation.collect(body: body, installation: installation, origin: origin)
    }
}
