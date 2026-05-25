# Architecture

## Goal

Build one Apple-native VPN product for iOS and macOS that imports Amnezia
configuration links and decides whether traffic should go through the encrypted
tunnel or directly through the current network provider.

## Apple Components

- `App`: SwiftUI app for import, connection state, routing rules, diagnostics,
  and traffic statistics.
- `PacketTunnelProvider`: Network Extension process that owns the tunnel and
  packet flow.
- `SharedCore`: Swift modules shared by iOS, macOS, and the extension.
- `Keychain`: storage for private keys and imported server credentials.
- App Group container: non-secret rule sets, logs, and shared preferences.

## Import Flow

1. User imports a `vpn://` link, QR code, `.vpn`, `.conf`, or `.json` file.
2. The app decodes the native Amnezia payload locally.
3. The payload is normalized into an internal protocol model.
4. Secrets are moved into Keychain.
5. The app creates or updates an `NETunnelProviderManager` profile.

The raw imported link should never be logged or written to a fixture.

## Routing Model

The app should support three user-facing modes:

- `All traffic`: default full-tunnel VPN.
- `Selected through VPN`: only chosen domains, IP ranges, or lists use the VPN.
- `Selected direct`: everything uses the VPN except chosen destinations.

The extension can apply route decisions in two layers:

- Apple route settings: `includedRoutes` and `excludedRoutes` for IP/CIDR rules.
- Packet-level policy: inspect destination IPs from packets and forward through
  tunnel or direct path when the selected protocol core supports it.

Domain rules require DNS handling:

- Resolve domain lists into IP ranges.
- Refresh mappings when DNS TTLs expire.
- Prefer encrypted DNS inside the tunnel when a rule depends on private DNS
  behavior.

## Regional Policy and Smart Selection

SmartVPN keeps hard routing rules deterministic:

- Destinations in the current country use the current provider and provider DNS.
- Destinations in the user's home region use a VPN server from that region.
- Other foreign destinations use the fastest healthy VPN server.
- User overrides have priority over built-in regional rules.

`SmartServerSelection` ranks VPN servers without seeing raw configs, private
keys, or full browsing history. Its public API is intentionally compatible with a
future Core ML backend: the current implementation is a local heuristic scorer
that consumes latency, packet loss, handshake time, recent failures, network
type, provider ASN metadata, and recent quality samples. Later, the scorer can be
replaced by a compact Core ML ranking model without changing the routing layer.

Quality history is local-only and should contain technical route metrics, not raw
`vpn://` links, decoded Amnezia payloads, private keys, or full domain names.

## Preventive Health Monitoring

SmartVPN should proactively probe both sides of the routing model:

- Direct path: provider DNS and local/current-region endpoints that must be
  reachable without VPN.
- VPN path: tunnel handshake, VPN DNS, and endpoints that must be reachable only
  through the selected VPN server.

The probe runner lives in the app or `PacketTunnelProvider` layer and can use
Network.framework, DNS queries, TCP connect checks, lightweight HTTP HEAD checks,
or tunnel-specific handshakes. `SmartServerSelection` only evaluates sanitized
probe results and recommends recovery actions:

- keep current tunnel when both paths are healthy;
- refresh provider DNS when direct path degrades;
- rehandshake or refresh VPN DNS when the VPN path degrades;
- switch to a better ranked server when the VPN path stalls or goes down;
- reconnect the active server if no replacement exists.

This health assessment API is another Core ML insertion point: a future model can
predict impending stalls from latency, packet loss, handshake jitter, repeated
DNS failures, network type, provider ASN, time of day, and historical recovery
success. Deterministic safety rules still win over model output.

## Protocol Plan

### Phase 1: Amnezia Native Link Import

Decode Amnezia native `vpn://` payloads and identify the inner protocol. The
current `AmneziaConfig` module covers the Base64 URL and Qt-compressed payload
layer.

### Phase 2: AmneziaWG

Add an AmneziaWG userspace adapter for the packet tunnel extension. This is the
most practical first protocol because it is close to WireGuard's tunnel model.

### Phase 3: Routing Rules

Add rule storage, route compilation, and diagnostics showing whether a
destination is routed through VPN or direct.

### Phase 3.5: Smart Server Selection

Use local quality history and a heuristic scorer to choose the fastest stable VPN
server for foreign traffic. Keep hard regional rules above the scorer.

### Phase 3.6: Preventive Health Monitoring

Continuously evaluate direct and VPN path probes to avoid common VPN hangs.
Recover by refreshing DNS, rehandshaking, changing tunnel parameters, switching
servers, or reconnecting.

### Phase 4: XRay/OpenVPN

Add protocol adapters after the AmneziaWG path is stable.

## Security Notes

- Do not store imported links in logs.
- Do not print decoded configs in crash reports.
- Keep private keys in Keychain.
- Redact endpoint credentials in diagnostics.
- Treat every imported config as untrusted input.
