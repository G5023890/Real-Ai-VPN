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

    func testDecodeShadowrocketVLESSRealityConfig() throws {
        let rawConfig = """
        {
          "type": "VLESS",
          "title": "DE Reality",
          "flag": "DE",
          "host": "example-vless.test",
          "port": "47538",
          "password": "02d97ea8-7018-48ea-add8-9f6634e43e85",
          "peer": "example.com",
          "publicKey": "test-public-key",
          "shortId": "d8a1ea76",
          "fp": "random",
          "spx": "/",
          "xtls": "2",
          "udp": "1"
        }
        """

        let config = try ShadowrocketVLESSConfigParser().parse(rawConfig)

        XCTAssertEqual(config.title, "DE Reality")
        XCTAssertEqual(config.regionCode, "DE")
        XCTAssertEqual(config.host, "example-vless.test")
        XCTAssertEqual(config.port, 47538)
        XCTAssertEqual(config.peer, "example.com")
        XCTAssertEqual(config.publicKey, "test-public-key")
        XCTAssertEqual(config.shortID, "d8a1ea76")
        XCTAssertEqual(config.flow, "xtls-rprx-vision")
        XCTAssertEqual(config.fingerprint, "random")
        XCTAssertEqual(config.spiderX, "/")
        XCTAssertTrue(config.udp)
    }

    func testDecodeVLESSRealityURL() throws {
        let rawURL = "vless://02d97ea8-7018-48ea-add8-9f6634e43e85@example-vless.test:47538?security=reality&sni=example.com&pbk=test-public-key&sid=d8a1ea76&flow=xtls-rprx-vision&fp=random&spx=%2F#DE%20Reality"

        let config = try ShadowrocketVLESSConfigParser().parse(rawURL)

        XCTAssertEqual(config.title, "DE Reality")
        XCTAssertEqual(config.host, "example-vless.test")
        XCTAssertEqual(config.port, 47538)
        XCTAssertEqual(config.uuid, "02d97ea8-7018-48ea-add8-9f6634e43e85")
        XCTAssertEqual(config.peer, "example.com")
        XCTAssertEqual(config.publicKey, "test-public-key")
        XCTAssertEqual(config.shortID, "d8a1ea76")
        XCTAssertEqual(config.flow, "xtls-rprx-vision")
        XCTAssertEqual(config.fingerprint, "random")
        XCTAssertEqual(config.spiderX, "/")
    }

    func testDecodeBase64SubscriptionPayloadWithVLESSAndUnsupportedEntries() throws {
        let rawURL = "vless://02d97ea8-7018-48ea-add8-9f6634e43e85@example-vless.test:47538?security=reality&sni=example.com&pbk=test-public-key&sid=d8a1ea76#DE"
        let mixedPayload = "hy2://ignored.example.test:443\n\(rawURL)\n"
        let encoded = Data(mixedPayload.utf8).base64EncodedString()

        let entries = try ShadowrocketVLESSConfigParser().parseEntries(encoded)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].profile.title, "DE")
        XCTAssertEqual(entries[0].profile.host, "example-vless.test")
        XCTAssertEqual(entries[0].rawConfig, rawURL)
    }

    func testDetectShadowrocketSubscribeURL() throws {
        let subscribeJSON = """
        {
          "type": "Subscribe",
          "host": "https://example.test/subscription"
        }
        """

        let url = try ShadowrocketVLESSConfigParser().subscriptionURL(from: subscribeJSON)

        XCTAssertEqual(url?.absoluteString, "https://example.test/subscription")
    }

    func testBuildSingBoxConfigFromShadowrocketVLESSReality() throws {
        let profile = ShadowrocketVLESSConfig(
            title: "DE Reality",
            regionCode: "DE",
            host: "example-vless.test",
            port: 47538,
            uuid: "02d97ea8-7018-48ea-add8-9f6634e43e85",
            peer: "example.com",
            publicKey: "test-public-key",
            shortID: "d8a1ea76",
            flow: "xtls-rprx-vision",
            fingerprint: "chrome",
            spiderX: "",
            udp: true
        )

        let config = try SingBoxConfigBuilder().build(from: profile)
        let data = try XCTUnwrap(config.jsonString.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first)
        let tls = try XCTUnwrap(proxy["tls"] as? [String: Any])
        let reality = try XCTUnwrap(tls["reality"] as? [String: Any])
        let utls = try XCTUnwrap(tls["utls"] as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let directDomainRule = try XCTUnwrap(rules.first { ($0["outbound"] as? String) == "direct" && $0["domain_suffix"] != nil })
        let directDomainSuffixes = try XCTUnwrap(directDomainRule["domain_suffix"] as? [String])
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let dnsServers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let cloudflareDNS = try XCTUnwrap(dnsServers.first)

        XCTAssertEqual(proxy["type"] as? String, "vless")
        XCTAssertEqual(proxy["server"] as? String, "example-vless.test")
        XCTAssertEqual(proxy["server_port"] as? Int, 47538)
        XCTAssertEqual(proxy["uuid"] as? String, "02d97ea8-7018-48ea-add8-9f6634e43e85")
        XCTAssertEqual(proxy["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual(tls["server_name"] as? String, "example.com")
        XCTAssertEqual(utls["fingerprint"] as? String, "chrome")
        XCTAssertEqual(reality["public_key"] as? String, "test-public-key")
        XCTAssertEqual(reality["short_id"] as? String, "d8a1ea76")
        XCTAssertNil(reality["spider_x"])
        XCTAssertTrue(directDomainSuffixes.contains("ru"))
        XCTAssertEqual(dns["final"] as? String, "cloudflare")
        XCTAssertEqual(cloudflareDNS["tag"] as? String, "cloudflare")
        XCTAssertEqual(cloudflareDNS["type"] as? String, "tls")
        XCTAssertEqual(cloudflareDNS["server"] as? String, "1.1.1.1")
        XCTAssertEqual(cloudflareDNS["server_port"] as? Int, 853)
        XCTAssertNil(cloudflareDNS["address"])
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
