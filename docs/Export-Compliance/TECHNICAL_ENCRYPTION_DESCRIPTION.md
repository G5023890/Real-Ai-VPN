# Technical encryption description

## Product and scope

Real Ai Router is an iOS and macOS VPN client. Version 0.98.5 (build 87) imports
user-supplied VLESS Reality configurations and operates a packet-tunnel
extension using Apple's `NetworkExtension` APIs. WireGuard is temporarily
excluded from the shipped targets.

The application does not invent, modify, or claim ownership of a cryptographic
protocol. It is not a general-purpose cryptographic toolkit, a key-management
product, or an encrypted-storage product.

## Encryption present in the product

| Component | Use in the product | Origin | Assessment |
| --- | --- | --- | --- |
| sing-box Libbox / VLESS Reality | Establishes the connection defined by a user-imported VLESS Reality configuration | sing-box Libbox | Uses the standard cryptographic facilities of the imported protocol and transport; not proprietary cryptography created by this app |
| Apple platform APIs | Packet-tunnel configuration, Keychain storage, TLS and networking where used by the platform | Apple operating systems | Platform-provided services |

The app therefore uses encryption beyond encryption limited solely to Apple's
operating systems. The encrypted tunnel is its core user-facing purpose.

## Protocol and source evidence

- `README.md` identifies the currently supported VLESS Reality workflow.
- `THIRD_PARTY_NOTICES.md` identifies sing-box Libbox as the shipped component.
- `Sources/PacketTunnelProvider/` and the sing-box extension targets start the
  VLESS packet tunnel.
- User profiles contain their own endpoint, public-key, and credential values.
  The app does not operate a VPN server and does not manufacture those keys.

## Intended App Store Connect responses

1. **Does the app use encryption?** — Yes.
2. **Is encryption limited to that within Apple's operating system?** — No.
3. **Does it use proprietary or unpublished cryptographic algorithms?** — No.
4. **Does it use published/industry-standard algorithms or protocols?** — Yes.

These answers describe the shipped source code. They do not determine an ECCN,
an export exception, a CCATS, or any country-specific import requirement. The
exporter must determine these separately and must not submit this technical
record as a government-issued classification.
