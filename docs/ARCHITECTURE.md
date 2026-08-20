# Architecture

## Goal

Build one Apple-native VPN product for iOS and macOS that imports VLESS Reality
links, subscriptions, and Xray JSON, then
decides whether traffic should go through the encrypted tunnel or directly through the current
network provider.

## Apple Components

- `App`: SwiftUI app for import, connection state, routing rules, diagnostics,
  and traffic statistics.
- `PacketTunnelProvider`: Network Extension process that owns the tunnel and
  packet flow.
- `SharedCore`: Swift modules shared by iOS, macOS, and the extension.
- `Keychain`: storage for private keys and imported server credentials.
- App Group container: non-secret rule sets, logs, and shared preferences.

## Import Flow

1. User imports a VLESS configuration, subscription, or Xray JSON. Standard
   WireGuard files may still be parsed for compatibility, but are not tunnel
   backends in the current release.
2. The app extracts the VLESS Reality outbound locally.
3. The configuration is normalized into an internal protocol model; Xray DNS, inbounds, and
   routing are deliberately not imported because the packet tunnel owns those policies.
4. Secrets are moved into Keychain.
5. The app creates or updates an `NETunnelProviderManager` profile.

The raw imported link should never be logged or written to a fixture.

## Remote Catalog Flow

1. The app downloads the public `user.signed.json` or `admin.signed.json`
   envelope directly from the configured GitHub raw-content URL.
2. Admin access is gated locally by the password hash published in
   `admin-access.json`; no GitHub token or Cloudflare service is used by the app.
3. The app verifies the Ed25519 signature against its configured public key and
   rejects expired or incompatible manifest versions.
4. The update is applied atomically. Only remote-owned profiles in that same
   catalog can be replaced or withdrawn; local imports are retained.

The GitHub credential and the signing private key must never be delivered in an
app binary, sent to a client, or committed to either repository. The Admin
password itself is never published; only its SHA-256 hash is stored.

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
private keys, raw configurations, or full domain names.

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

## Protocol Status

### Current: VLESS Reality

Run VLESS Reality through the sing-box packet tunnel. Import VLESS URLs and
subscriptions, and extract compatible VLESS Reality outbounds from Xray JSON.
Other Xray outbound protocols and OpenVPN are not supported.

### Deferred: WireGuard runtime

The standard WireGuard parser remains in the shared modules for import and
migration compatibility, but the WireGuard userspace runtime, extension
targets, and `libwg-go` are excluded from the 0.98.5 iOS and macOS products.

### Routing Rules

Add rule storage, route compilation, and diagnostics showing whether a
destination is routed through VPN or direct.

### Phase 3.5: Smart Server Selection

Use local quality history and a heuristic scorer to choose the fastest stable VPN
server for foreign traffic. Keep hard regional rules above the scorer.

### Phase 3.6: Preventive Health Monitoring

Continuously evaluate direct and VPN path probes to avoid common VPN hangs.
Recover by refreshing DNS, rehandshaking, changing tunnel parameters, switching
servers, or reconnecting.

## Security Notes

- Do not store imported links in logs.
- Do not print decoded configs in crash reports.
- Keep private keys in Keychain.
- Redact endpoint credentials in diagnostics.
- Treat every imported config as untrusted input.
