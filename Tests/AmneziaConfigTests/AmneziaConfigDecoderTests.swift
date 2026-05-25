import Compression
import Foundation
import XCTest

@testable import AmneziaConfig

final class AmneziaConfigDecoderTests: XCTestCase {
    func testDecodeQtCompressedVpnURL() throws {
        let payload = #"{"protocol":"awg","description":"synthetic fixture"}"#.data(using: .utf8)!
        let url = try makeVPNURL(payload: payload)

        let decoded = try AmneziaConfigDecoder().decodeString(from: url)

        XCTAssertEqual(decoded, String(data: payload, encoding: .utf8))
    }

    func testDecodeQtCompressedVpnURLWithUndersizedHeader() throws {
        let payload = #"{"protocol":"awg","description":"synthetic fixture with a slightly longer body"}"#.data(using: .utf8)!
        let url = try makeVPNURL(payload: payload, declaredSize: 8)

        let decoded = try AmneziaConfigDecoder().decodeString(from: url)

        XCTAssertEqual(decoded, String(data: payload, encoding: .utf8))
    }

    func testRejectsNonVpnScheme() {
        XCTAssertThrowsError(try AmneziaConfigDecoder().decodePayload(from: "wg://abc")) { error in
            XCTAssertEqual(error as? AmneziaConfigDecodeError, .invalidScheme)
        }
    }

    func testDecodeWireGuardConfigBuildsWgQuickText() throws {
        let payload = """
        {
          "interface": {
            "privateKey": "private-test-key",
            "address": "10.8.0.2/32",
            "dns": "1.1.1.1",
            "jc": "4",
            "jmin": "40",
            "jmax": "70"
          },
          "peer": {
            "publicKey": "public-test-key",
            "presharedKey": "psk-test-key",
            "endpoint": "203.0.113.10:51820",
            "allowedIPs": "0.0.0.0/0, ::/0",
            "persistentKeepalive": 25
          }
        }
        """.data(using: .utf8)!
        let url = try makeVPNURL(payload: payload)

        let config = try AmneziaConfigDecoder().decodeWireGuardConfig(from: url)

        XCTAssertEqual(config.endpoint, "203.0.113.10:51820")
        XCTAssertTrue(config.wgQuickConfig.contains("PrivateKey = private-test-key"))
        XCTAssertTrue(config.wgQuickConfig.contains("PublicKey = public-test-key"))
        XCTAssertTrue(config.wgQuickConfig.contains("Jc = 4"))
        XCTAssertTrue(config.wgQuickConfig.contains("AllowedIPs = 0.0.0.0/0, ::/0"))
    }

    func testDecodeImportedRawAmneziaWGConfig() throws {
        let rawConfig = """
        [Interface]
        Address = 100.89.149.137/32
        DNS = 100.64.0.1, 8.8.4.4
        PrivateKey = private-test-key
        Jc = 3
        Jmin = 10
        Jmax = 50
        S1 = 71
        S2 = 132
        H1 = 218384200
        H2 = 682575538
        H3 = 1155940141
        H4 = 1498051959

        [Peer]
        PublicKey = public-test-key
        PresharedKey = psk-test-key
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 185.215.184.67:3374
        PersistentKeepalive = 25
        """

        let config = try AmneziaConfigDecoder().decodeImportedWireGuardConfig(from: rawConfig)

        XCTAssertEqual(config.endpoint, "185.215.184.67:3374")
        XCTAssertEqual(config.address, "100.89.149.137/32")
        XCTAssertEqual(config.jc, "3")
        XCTAssertEqual(config.h4, "1498051959")
        XCTAssertTrue(config.wgQuickConfig.contains("PresharedKey = psk-test-key"))
    }

    func testPremiumSubscriptionTokenNeedsGatewayConfig() throws {
        let payload = """
        {
          "name": "Amnezia Premium",
          "description": "Amnezia Premium",
          "config_version": 2,
          "api_config": {
            "service_type": "amnezia-premium",
            "service_protocol": "awg",
            "user_country_code": "ru"
          },
          "auth_data": {
            "api_key": "redacted-test-key"
          }
        }
        """.data(using: .utf8)!
        let url = try makeVPNURL(payload: payload)

        XCTAssertThrowsError(try AmneziaConfigDecoder().decodeWireGuardConfig(from: url)) { error in
            XCTAssertEqual(error as? AmneziaWireGuardConfigError, .premiumSubscriptionRequiresGatewayConfig)
        }
    }

    func testWireGuardRedactedSummaryDoesNotExposeKeys() throws {
        let config = AmneziaWireGuardConfig(
            privateKey: "private-test-key",
            address: "10.8.0.2/32",
            dns: "1.1.1.1",
            publicKey: "public-test-key",
            endpoint: "203.0.113.10:51820"
        )

        XCTAssertFalse(config.redactedSummary.contains("private-test-key"))
        XCTAssertFalse(config.redactedSummary.contains("public-test-key"))
        XCTAssertTrue(config.redactedSummary.contains("203.0.113.10:51820"))
    }

    private func makeVPNURL(payload: Data, declaredSize: Int? = nil) throws -> String {
        var compressed = Data(count: payload.count + 64)

        let written = compressed.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { inputBytes in
                compression_encode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    outputBytes.count,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    inputBytes.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        XCTAssertGreaterThan(written, 0)
        compressed.removeSubrange(written..<compressed.count)

        let size = declaredSize ?? payload.count
        var qtPayload = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff)
        ])
        qtPayload.append(compressed)

        let encoded = qtPayload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return "vpn://\(encoded)"
    }
}
