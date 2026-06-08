# Real Ai VPN

Real Ai VPN is a SwiftUI VPN client for iOS and macOS. It imports AmneziaWG
profiles, Shadowrocket VLESS Reality links/subscriptions, and runs them through
Apple `NetworkExtension` packet tunnel providers.

The current app is ready for the next Core ML step: the routing, health, profile,
and diagnostics layers are in place, while server choice still uses deterministic
rules and heuristic scoring through the `SmartServerSelection` API.

## Current Functionality

- Platforms: native iOS and macOS apps with SwiftUI and Apple Liquid Glass style.
- VPN engine: `NEPacketTunnelProvider` profiles for AmneziaWG and sing-box VLESS
  Reality.
- Imports: Amnezia native `vpn://` links, raw AmneziaWG configs, VLESS Reality
  URLs, and base64 Shadowrocket subscription payloads.
- Routing: user-managed `Bypass VPN` and `Through VPN` rules for exact domains,
  suffixes, IP addresses, and CIDR ranges.
- Navigation: macOS keeps `Dashboard`, `VPN Profiles`, `Routing`, `Settings`,
  and `Stat` as top-level sections; iOS exposes the same operational areas as
  tabs for quick device validation.
- DNS policy: VLESS/sing-box routes provider/direct DNS through Yandex DNS while
  VPN-protected DNS uses Cloudflare DNS-over-TLS through the proxy lane.
- Reconnect flow: Routing has a `Reconnect` action on macOS and iOS that enables
  Kill Switch before restarting the active tunnel so new routing rules are
  applied.
- Statistics: the `Stat` section summarizes direct/provider and tunnel health,
  per-channel latency, packet loss, handshake timing, success rate, failure
  counts, last sample time, active/connected state, and ranking score.
- Security settings: Kill Switch, DNS protection, local network access, IPv6 leak
  protection, auto recovery, and notification controls.
- macOS app behavior: menu bar mode, dock visibility, launch at login, and menu
  bar actions for open/connect/disconnect/settings/quit.
- Preventive health: direct and VPN probes feed recovery decisions that can
  refresh DNS, rehandshake, switch profiles, or reconnect.
- Diagnostics: packet tunnel stop reasons and provider errors are persisted for
  investigation after disconnects.

## Core Modules

- `AmneziaConfig`: decodes and normalizes imported VPN profiles.
- `RealVPNCore`: owns NetworkExtension profile creation, routing exception
  persistence, and tunnel diagnostics.
- `PacketTunnelProvider`: starts AmneziaWG or sing-box tunnels and compiles
  routing exceptions into tunnel configuration.
- `SmartServerSelection`: ranks and selects profiles with deterministic and
  heuristic logic; this is the planned Core ML integration point.
- `SmartVPNMacApp` and `SmartVPNiOSApp`: platform UI, settings, routing,
  profile management, reconnect controls, and channel statistics surfaces.

## Current Restore Point

- `restore-stat-channels`: readiness point after moving Routing to a top-level
  app section, adding the `Stat` statistics/channels view to macOS and iOS,
  removing the macOS-only `Connection` settings subsection from the visible UI,
  and validating fresh macOS/iOS device builds.

## Local Checks

```sh
swift test
```

## Build

macOS:

```sh
./scripts/build_and_install_app.sh
```

iOS device:

```sh
./scripts/build_ios_device_app.sh
```

The iOS script builds for a real device product. Install the resulting app with
`xcrun devicectl`; do not use a simulator for device validation.
