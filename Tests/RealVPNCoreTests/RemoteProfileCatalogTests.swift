import CryptoKit
import XCTest
@testable import RealVPNCore

final class RemoteProfileCatalogTests: XCTestCase {
    func testVerifiesSignedManifestAndAcceptsBase64URL() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = RemoteCatalogManifest(
            catalogID: "primary",
            role: .user,
            revision: "2026-08-07T12:00:00Z",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            profiles: [
                RemoteCatalogProfile(
                    id: "stockholm-1",
                    displayName: "Stockholm",
                    kind: .wireGuardConfig,
                    regionCode: "SE",
                    endpointHost: "se.example.com",
                    config: "[Interface]\\nPrivateKey = test"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(manifest)
        let signature = try privateKey.signature(for: payload)
        let envelope = SignedRemoteCatalogEnvelope(
            payload: base64URL(payload),
            signature: base64URL(signature)
        )

        let verified = try RemoteCatalogClient().verify(
            envelope: envelope,
            publicKey: base64URL(privateKey.publicKey.rawRepresentation),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(verified.catalogID, "primary")
        XCTAssertEqual(verified.profiles.first?.id, "stockholm-1")
    }

    func testRejectsModifiedManifest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = RemoteCatalogManifest(
            catalogID: "primary", role: .user, revision: "1",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000), profiles: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(manifest)
        let signature = try privateKey.signature(for: payload)
        var altered = payload
        altered.append(0)
        let envelope = SignedRemoteCatalogEnvelope(payload: base64URL(altered), signature: base64URL(signature))

        XCTAssertThrowsError(try RemoteCatalogClient().verify(
            envelope: envelope,
            publicKey: base64URL(privateKey.publicKey.rawRepresentation),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )) { error in
            XCTAssertEqual(error as? RemoteCatalogError, .invalidSignature)
        }
    }

    func testRemoteProfileKeepsStableRemoteIdentity() {
        let profile = RemoteCatalogProfile(
            id: "stockholm-1", displayName: "Stockholm", kind: .singBoxVLESSReality, config: "vless://example"
        ).storedProfile()
        XCTAssertEqual(profile.source, .remoteCatalog)
        XCTAssertEqual(profile.remoteProfileID, "stockholm-1")
    }

    func testAcceptsCorrectAdminPasswordHash() throws {
        let password = "test-admin-password"
        let digest = SHA256.hash(data: Data(password.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let access = RemoteCatalogAdminAccess(catalogID: "primary", passwordSHA256: hash)

        XCTAssertNoThrow(try RemoteCatalogClient().verifyAdminPassword(password, access: access))
        XCTAssertThrowsError(try RemoteCatalogClient().verifyAdminPassword("wrong", access: access)) { error in
            XCTAssertEqual(error as? RemoteCatalogError, .invalidAdminPassword)
        }
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
