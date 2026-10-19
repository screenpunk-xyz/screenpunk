import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: sign-ed25519 PRIVATE_KEY MESSAGE_FILE\n", stderr)
    exit(64)
}
let secret = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard secret.count == 32 else { fatalError("Expected a raw 32-byte Ed25519 private key") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
let message = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
print(try key.signature(for: message).base64EncodedString())
