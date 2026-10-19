import Foundation
#if os(macOS)
import Darwin
import Security

/// Read-only static code verification for a catalog-approved executable. The caller also hashes
/// the open fd and checks its metadata; this backend rejects a path that no longer names that fd.
struct MacOSToolchainSignatureVerifier: ToolchainExecutableSignatureVerifying {
    func verify(fd: Int32, path: String, expected: ToolchainPublisher) throws {
        try expected.validate()
        guard WorkspaceValidation.absolute(path) else { throw ToolchainTrustError.unsafePath }
        let opened = try metadata(fd: fd)
        let before = try metadata(path: path)
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), same(opened, before) else {
            throw ToolchainTrustError.unsafePath
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                          SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { throw ToolchainTrustError.publisherUnverified }
        let source = "anchor apple generic and certificate leaf[subject.OU] = \"\(expected.teamIdentifier)\" and identifier \"\(expected.signingIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { throw ToolchainTrustError.publisherUnverified }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else {
            throw ToolchainTrustError.publisherUnverified
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signed = information as? [String: Any],
              signed[kSecCodeInfoTeamIdentifier as String] as? String == expected.teamIdentifier,
              signed[kSecCodeInfoIdentifier as String] as? String == expected.signingIdentifier else {
            throw ToolchainTrustError.publisherUnverified
        }
        let after = try metadata(path: path)
        guard same(opened, after), same(opened, try metadata(fd: fd)) else {
            throw ToolchainTrustError.unsafePath
        }
    }

    private func metadata(fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ToolchainTrustError.unsafePath }
        return value
    }
    private func metadata(path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else { throw ToolchainTrustError.unsafePath }
        return value
    }
    private func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
#endif
