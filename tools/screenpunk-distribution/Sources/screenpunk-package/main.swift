import Foundation
import ScreenpunkDistribution
import CryptoKit

let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.count == 4, args[0] == "assemble-local-test",
       DistributionArchive.validVersion(args[3]) {
        let manifest = try DistributionArchive.assembleLocalTest(
            payload: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]),
            version: args[3])
        print("Created local-test distribution \(manifest.version) with \(manifest.files.count) measured files at \(args[2])")
    } else if args.count == 2, args[0] == "verify-local-test" {
        let manifest = try DistributionArchive.verify(root: URL(fileURLWithPath: args[1]), allowLocalTest: true)
        print("Verified local-test distribution \(manifest.version) with \(manifest.files.count) measured files at \(args[1])")
    } else if args.count == 5, args[0] == "assemble-release",
              DistributionArchive.validVersion(args[3]) {
        let privateBytes = try Data(contentsOf: URL(fileURLWithPath: args[4]))
        guard privateBytes.count == 32 else { throw DistributionError.untrustedRelease }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes)
        guard key.publicKey.rawRepresentation == ScreenpunkProductionReleaseTrust.publicKeyRaw else {
            throw DistributionError.untrustedRelease
        }
        let manifest = try DistributionArchive.assembleAuthenticatedRelease(
            payload: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]),
            version: args[3], keyId: ScreenpunkProductionReleaseTrust.keyId,
            sign: { try key.signature(for: $0) },
            releaseTrust: ScreenpunkProductionReleaseTrust())
        print("Created authenticated release \(manifest.version) with \(manifest.files.count) measured files at \(args[2])")
    } else if args.count == 2, args[0] == "verify-release" {
        let manifest = try DistributionArchive.verify(root: URL(fileURLWithPath: args[1]),
            allowLocalTest: false, releaseTrust: ScreenpunkProductionReleaseTrust())
        print("Verified authenticated release \(manifest.version) with \(manifest.files.count) measured files at \(args[1])")
    } else {
        fputs("usage: screenpunk-package assemble-local-test PAYLOAD OUTPUT VERSION | verify-local-test ROOT | assemble-release PAYLOAD OUTPUT VERSION PRIVATE_KEY_PATH | verify-release ROOT\n", stderr)
        exit(64)
    }
} catch {
    fputs("screenpunk-package: \(error)\n", stderr)
    exit(1)
}
