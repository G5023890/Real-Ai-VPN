import CryptoKit
import Foundation
guard CommandLine.arguments.count == 2 else { fputs("Usage: swift generate_signing_key.swift <output-directory>\\n", stderr); exit(1) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let privateKey = Curve25519.Signing.PrivateKey()
let privateURL = directory.appendingPathComponent("catalog-signing-private.key")
let publicURL = directory.appendingPathComponent("catalog-signing-public.key")
try privateKey.rawRepresentation.base64EncodedString().write(to: privateURL, atomically: true, encoding: .utf8)
try privateKey.publicKey.rawRepresentation.base64EncodedString().write(to: publicURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
print("Created signing key files in \(directory.path). Keep catalog-signing-private.key outside Git.")
