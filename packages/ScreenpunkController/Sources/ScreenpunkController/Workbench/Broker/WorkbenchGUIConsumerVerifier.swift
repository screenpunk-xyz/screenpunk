import Foundation

#if os(macOS)
import Darwin
import Security

/// Only the host installs this verifier. The wire protocol supplies no PID,
/// executable path, signature claim or GUI role.
public protocol WorkbenchGUIConsumerVerifier {
    func verifyConnectedPeer(socket: Int32) -> Bool
}

/// Release configuration must supply an independently approved requirement
/// for the compatible GUI identifier and publisher. An absent verifier keeps
/// consumer evidence unknown and registration closed.
public final class WorkbenchSignedGUIConsumerVerifier: WorkbenchGUIConsumerVerifier {
    private let requirement: SecRequirement

    public init(requirementText: String) throws {
        guard !requirementText.isEmpty else { throw WorkbenchIPCError(.invalidConfiguration) }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString,
            SecCSFlags(), &parsed) == errSecSuccess,
            let parsed else { throw WorkbenchIPCError(.invalidConfiguration) }
        requirement = parsed
    }

    public func verifyConnectedPeer(socket: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard Darwin.getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size else { return false }
        let auditData = withUnsafeBytes(of: &token) { bytes in
            CFDataCreate(kCFAllocatorDefault, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                bytes.count)
        }
        guard let auditData else { return false }
        let attributes = [kSecGuestAttributeAudit as String: auditData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(),
            &guest) == errSecSuccess, let guest else { return false }
        return SecCodeCheckValidity(guest, SecCSFlags(), requirement) == errSecSuccess
    }
}
#endif
