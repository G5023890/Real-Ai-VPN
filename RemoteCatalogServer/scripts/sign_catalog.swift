import CryptoKit
import Foundation
guard CommandLine.arguments.count == 4 else { fputs("Usage: swift sign_catalog.swift <manifest.json> <private-key-file> <output.signed.json>\\n", stderr); exit(1) }
let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let payload = try Data(contentsOf: manifestURL)
let privateText = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let privateData = Data(base64Encoded: privateText) else { throw CocoaError(.fileReadCorruptFile) }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
let signature = try key.signature(for: payload)
let envelope: [String: String] = ["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()]
let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
try data.write(to: outputURL, options: .atomic)
print("Signed \(manifestURL.lastPathComponent) -> \(outputURL.path)")
