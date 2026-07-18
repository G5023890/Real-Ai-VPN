import XCTest
@testable import WireGuardConfig

final class WireGuardConfigDecoderTests: XCTestCase {
    func testDecodesStandardWireGuardConfiguration() throws {
        let config = try WireGuardConfigDecoder().decodeImportedWireGuardConfig(from: """
        [Interface]
        PrivateKey = private-test-key
        Address = 10.9.40.42/32
        DNS = 10.12.0.1

        [Peer]
        PublicKey = public-test-key
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = tlv-il.example.com:51820
        PersistentKeepalive = 25
        """)

        XCTAssertEqual(config.address, "10.9.40.42/32")
        XCTAssertEqual(config.dns, "10.12.0.1")
        XCTAssertEqual(config.endpoint, "tlv-il.example.com:51820")
        XCTAssertEqual(config.persistentKeepalive, 25)
        XCTAssertFalse(config.wgQuickConfig.lowercased().contains("jc ="))
    }

    func testRejectsAmneziaWGOnlyFields() {
        let configuration = """
        [Interface]
        PrivateKey = private-test-key
        Jc = 4

        [Peer]
        PublicKey = public-test-key
        Endpoint = tlv-il.example.com:51820
        """

        XCTAssertThrowsError(try WireGuardConfigDecoder().decodeImportedWireGuardConfig(from: configuration)) { error in
            XCTAssertEqual(error as? WireGuardConfigError, .unsupportedAmneziaWGField("jc"))
        }
    }

    func testRequiresWireGuardInterfaceAndPeerFields() {
        XCTAssertThrowsError(try WireGuardConfigDecoder().decodeImportedWireGuardConfig(from: "[Interface]\nAddress = 10.0.0.2/32"))
    }

    func testRecognizesDirectHTTPSSubscriptionURL() throws {
        let url = try ShadowrocketVLESSConfigParser().subscriptionURL(
            from: "https://example.com/subscription"
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com/subscription")
    }

    func testImportsXrayVLESSRealityConfiguration() throws {
        let profile = try ShadowrocketVLESSConfigParser().parse("""
        {
          "remarks": "Stockholm",
          "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{
              "address": "vpn.example.com", "port": 443,
              "users": [{"id": "00000000-0000-4000-8000-000000000000", "flow": "xtls-rprx-vision"}]
            }]},
            "streamSettings": {
              "network": "tcp", "security": "reality",
              "realitySettings": {
                "fingerprint": "firefox", "publicKey": "test-public-key",
                "serverName": "vpn.example.com", "spiderX": "/"
              }
            }
          }]
        }
        """)

        XCTAssertEqual(profile.title, "Stockholm")
        XCTAssertEqual(profile.endpoint, "vpn.example.com:443")
        XCTAssertEqual(profile.peer, "vpn.example.com")
        XCTAssertEqual(profile.flow, "xtls-rprx-vision")
        XCTAssertEqual(profile.fingerprint, "firefox")
    }
}
