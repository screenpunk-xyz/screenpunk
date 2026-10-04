import Foundation

/// Static package transport only. No installation authority, admission, activation or selection lease.
@_spi(ManagedRender) public enum DeviceManagedRenderFailure:Error,Equatable {
    case unsupportedCapabilities,invalidContent,emptySelection,sizeLimit
}
@_spi(ManagedRender) public struct DeviceManagedRenderAsset:Sendable {
    public let path:String
    public let bytes:Data
    fileprivate init(_ path:String,_ bytes:Data){self.path=path;self.bytes=bytes}
}
/// Constructed only from genuine qualified package bytes. Resource validation retains the original
/// completed restore's FOUR checkpoints; it never refreshes them or grants Cloud/Local authority.
/// The nonsecret asset snapshot is immutable. Scheme requests serve this snapshot without another
/// store check per asset; a future admitted owner must invalidate the presentation lifetime on
/// revocation. Construction/update checks are resource checks, not ongoing execution authority.
@_spi(ManagedRender) public final class DeviceManagedStaticContent:@unchecked Sendable {
    public let operationID:UUID,generationID:UUID,entryID:UUID
    public let displayName:String,entrypoint:String,revision:String
    public let assets:[DeviceManagedRenderAsset]
    private let validate:()throws->Void
    fileprivate init(operationID:UUID,generationID:UUID,entryID:UUID,displayName:String,
                     package:QualifiedDevicePackage,validate:@escaping ()throws->Void){
        self.operationID=operationID;self.generationID=generationID;self.entryID=entryID
        self.displayName=displayName;entrypoint=package.manifest.entrypoint;revision=package.revision.revision
        assets=[.init("manifest.json",package.originalManifestBytes)]+package.files.map{.init($0.path,$0.bytes)}
        self.validate=validate
    }
    /// Fresh resource check only; success does not authorize presentation or network work.
    public func verifyResources()throws {try Task.checkCancellation();try validate();try Task.checkCancellation()}
}
/// Internal factory requires the unforgeable qualified-package result. The validator is a resource
/// verifier, never an injected admission decision; production issuance occurs only in the shared gate.
enum DeviceManagedRenderProjection {
    static func make(package:QualifiedDevicePackage,operationID:UUID,generationID:UUID,entryID:UUID,
                     displayName:String,validate:@escaping ()throws->Void)throws->DeviceManagedStaticContent {
        guard package.manifest.connections.isEmpty,
              package.manifest.eventRules?.isEmpty != false,
              package.manifest.deviceBehavior?.temporaryActivation == nil,
              package.manifest.deviceBehavior?.audio == nil else{throw DeviceManagedRenderFailure.unsupportedCapabilities}
        guard package.files.count <= PackageLimits.maxFiles,package.originalManifestBytes.count <= DevicePackageQualifier.manifestLimit,
              displayName.utf8.count <= 4096 else{throw DeviceManagedRenderFailure.sizeLimit}
        var total=package.originalManifestBytes.count
        for file in package.files {
            guard file.path.utf8.count <= DevicePackageQualifier.pathLimit,file.bytes.count <= PackageLimits.expandedBytes-total else{throw DeviceManagedRenderFailure.sizeLimit}
            total += file.bytes.count
        }
        guard package.files.contains(where:{$0.path.utf8.elementsEqual(package.manifest.entrypoint.utf8)}) else{throw DeviceManagedRenderFailure.invalidContent}
        return .init(operationID:operationID,generationID:generationID,entryID:entryID,displayName:displayName,package:package,validate:validate)
    }
}
