# SmartVPN

Starter workspace for an iOS and macOS VPN client that can import Amnezia native
`vpn://` links and route traffic selectively through a tunnel or directly through
the current provider.

The first module is `AmneziaConfig`, a small Swift decoder for Amnezia native
share links. It intentionally keeps real VPN keys out of source control and test
fixtures.

## Direction

- UI: SwiftUI with Apple Liquid Glass style.
- VPN engine: `NetworkExtension` with `NEPacketTunnelProvider`.
- First protocol target: AmneziaWG, because it maps closest to WireGuard-style
  packet tunneling.
- Routing: split-tunnel rules by IP/CIDR first, then domain-derived rules via
  DNS resolution.
- Smart server choice: deterministic regional rules first, heuristic scoring now,
  Core ML ranking later behind the same `SmartServerSelection` API.
- Preventive health: evaluate direct/VPN probes before users feel a stall, then
  refresh DNS, rehandshake, switch servers, or reconnect.

## Local Checks

```sh
swift test
```

## macOS Prototype

```sh
./scripts/build_macos_app.sh
open "dist/Real Ai VPN.app"
```
