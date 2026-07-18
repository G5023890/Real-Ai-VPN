# Real Ai Router

Current release: `0.98`.

Current recovery point: `restore-0.98-wireguard-vless-xray-macos-profile-import`.

Real Ai Router is a SwiftUI VPN client for iOS and macOS. It imports standard
WireGuard profiles, VLESS Reality links/subscriptions, and Xray VLESS Reality
JSON configurations, and runs them through Apple `NetworkExtension` packet tunnel providers.

The app uses Apple Liquid Glass style across iOS and macOS and targets the latest
Apple beta SDKs through Xcode-beta. iOS builds are validated on a physically
connected iPhone, not in a simulator.

## Current Functionality

- Platforms: native iOS and macOS apps with matched operational areas for Home,
  Profiles, Route, Settings, Stat, and About.
- VPN engine: `NEPacketTunnelProvider` profiles for WireGuard and sing-box VLESS
  Reality.
- Imports: standard WireGuard `.conf` profiles, VLESS Reality URLs, direct HTTPS
  subscriptions, base64 Shadowrocket subscription payloads, and Xray VLESS/Reality JSON.
- Routing: user-managed `Bypass VPN` and `Through VPN` rules for exact domains,
  suffixes, IP addresses, and CIDR ranges.
- Protected probe endpoints: provider and VPN health-check names/IPs cannot be
  added to routing exceptions, so diagnostics and Core AI scoring cannot be
  accidentally excluded from the tunnel.
- DNS policy: VLESS/sing-box routes provider/direct DNS through Yandex DNS while
  VPN-protected DNS uses Cloudflare DNS-over-TLS through the proxy lane.
- Local network support: Bonjour, AirDrop, multicast, local IPv4/IPv6 discovery,
  APNs, and Apple device communication are kept outside the tunnel when local
  network access is enabled.
- Kill Switch: full-route NetworkExtension enforcement is preserved while local
  Apple device communication can remain reachable through the local-network
  bypass rules.
- Reconnect flow: Routing has a `Reconnect` action on macOS and iOS that
  restarts the active tunnel so new routing rules are applied.
- Drop/reset recovery: when Reconnect after dropped/reset is enabled, unexpected
  disconnect retries the last connected VPN profile up to five times, then
  quarantines the failed profile and uses failover logic to choose a healthier
  fallback.
- Manual Disconnect disables NetworkExtension On Demand before stopping the
  tunnel, so user-initiated disconnects are not interrupted by automatic
  reconnect.
- Profile switching: WireGuard and VLESS are serialized through one shared
  NetworkExtension transition. The previous Real Ai Router tunnel must fully
  disconnect before the selected profile is reloaded from system preferences
  and started. This avoids stale-session races when switching protocols on
  recent macOS and iOS releases.
- Transition diagnostics: while a VPN is changing state, macOS and iOS show
  the current system-profile stage: stopping the old tunnel, loading and
  saving the selected profile, starting its provider, or a concrete failure.
- iOS connect button behavior: the main Connect/Disconnect control has a larger
  tap target, an explicit busy state, and a full-area gesture handler to avoid
  missed taps during startup/status transitions.
- Settings parity: iOS and macOS expose the same security and behavior controls;
  the old Language block is removed, and Region blocks are collapsed by default.
- Statistics: `Stat` keeps Live Health, then shows the current profile with
  Core AI/CoreML details and standby VPN channels as a compact score ranking.
- Core AI Debugger: read-only debugger is available only from About on iOS and
  macOS, using real profiles and probe/ranking data.
- Preventive health: direct/provider and VPN-protected probes feed recovery
  decisions that can refresh DNS, rehandshake, switch profiles, or reconnect.
- Diagnostics: packet tunnel stop reasons and provider errors are persisted for
  investigation after disconnects.

## Recent 0.98 Changes

- Replaced AmneziaWG with the official WireGuard userspace adapter on iOS and
  macOS. Standard WireGuard `.conf` profiles are now the native WireGuard path;
  AmneziaWG-only obfuscation fields are rejected with an explicit import error.
- Added import of full Xray VLESS Reality JSON configurations alongside VLESS
  URLs and subscriptions. The app extracts the VLESS outbound and Reality
  parameters while retaining its own secure iOS/macOS tunnel routing and DNS policy.
- Restored the macOS profile-add flow: the `+` menu is always available, and an
  empty profile list presents `Paste configuration` and `Choose file` actions
  instead of demonstration servers.
- Matched the macOS and iOS profile workflow for WireGuard and VLESS Reality:
  import, select, rename, delete, reconnect, diagnostics, failover, and security controls.
- Raised default app release version from `0.97` to `0.98` in XcodeGen and all
  macOS/iOS build scripts.

## Recent 0.97 Changes

- Hardened WireGuard/VLESS system-profile switching for macOS 27 beta 3 and iOS:
  overlapping connection attempts are superseded, all Real Ai Router tunnel
  managers are stopped before a new provider starts, and the selected manager
  is reloaded from `NetworkExtension` preferences after saving.
- Increased profile-switch disconnect waits to 15 seconds so a slower system
  extension teardown cannot race the next VLESS or WireGuard start.
- Raised default app release version from `0.96` to `0.97` in XcodeGen and build
  scripts.
- Added a shared VLESS Reality compatibility route for Apple Mail account
  flows on macOS and iOS.
- Forced Apple/Google auth and account endpoints through the VPN/proxy DNS path
  while preventing Google/Apple domains from falling into direct/provider DNS
  suffix rules.
- Rejected QUIC `UDP/443` in sing-box so Apple Mail/WebKit can fall back to a
  predictable TCP/TLS path.
- Routed legacy mail TCP ports (`25`, `110`, `143`, `465`, `585`, `587`,
  `993`, `995`) through the direct compatibility path to avoid VLESS Reality
  IMAP/SMTP TLS negotiation hangs seen in Apple Mail.
- Removed the broad Apple `17.0.0.0/8` bypass from VLESS system route excludes
  so Apple auth traffic is not accidentally split away from Google auth during
  account setup.
- Improved sing-box traffic snapshots so macOS avoids mirrored RX/TX totals and
  iOS can use command connection deltas for more realistic upload/download
  counters.

## Recent 0.96 Changes

- Raised default app release version from `0.95` to `0.96` in XcodeGen and build
  scripts.
- Added a shared `RoutingExceptionProtectedProbeGuard` in `RealVPNCore`.
- Blocked health-check domains and IPs from routing exceptions on iOS and macOS.
- Improved iOS Connect/Disconnect UI with explicit busy text, a faded disabled
  state during VPN actions, larger height, and a full tappable area.
- Delayed initial iOS profile preparation and monitoring probes so app startup
  gives priority to the UI.
- Preserved AirDrop/Bonjour/local discovery bypass behavior while keeping VPN
  route and Kill Switch changes isolated.

## Core Modules

- `WireGuardConfig`: validates and normalizes standard WireGuard profiles.
- `RealVPNCore`: owns NetworkExtension profile creation, routing exception
  persistence, protected probe validation, and tunnel diagnostics.
- `PacketTunnelProvider`: starts WireGuard or sing-box tunnels and compiles
  routing exceptions into tunnel configuration.
- `SmartServerSelection`: ranks and selects profiles with deterministic and
  heuristic logic; this is the Core AI/CoreML scoring integration point.
- `SmartVPNMacApp` and `SmartVPNiOSApp`: platform UI, settings, routing,
  profile management, reconnect controls, debugger, and channel statistics.

## Recovery Points

- `restore-0.98-wireguard-vless-xray-macos-profile-import`: recovery point for
  the WireGuard migration, Xray/VLESS Reality JSON import, and restored macOS
  profile-add experience with iOS feature parity.
- `restore-0.97-macos-profile-switching`: recovery point for serialized WireGuard /
  VLESS system-profile transitions, refreshed NetworkExtension preferences,
  15-second teardown handling, and visible transition diagnostics on macOS and
  iOS.
- `restore-0.97-vless-mail-compatibility`: recovery point after fixing Apple
  Mail Google account authorization with VLESS Reality on macOS and iOS via
  shared auth routing, QUIC fallback, and legacy mail TLS-port compatibility.
- `restore-0.95-protected-probes-ios-button`: recovery point after protected
  probe exception blocking, iOS button responsiveness work, AirDrop/Bonjour
  route handling, iOS ReConnect fixes, Settings parity, and Stat/Core AI
  debugger updates.
- `restore-0.95-core-ai-debugger-stat`: recovery point for the read-only Core AI
  Debugger in About and the Stat ranking structure.
- `restore-v0.94-airdrop-killswitch-dns`: recovery point for the V0.94
  TestFlight candidate with AirDrop/Bonjour, Kill Switch, DNS, and local network
  access corrections.
- `restore-0.93-recovery-killswitch`: recovery point after bounded
  dropped/reset reconnect attempts, forced fallback after five failures, manual
  Disconnect protection from On Demand auto-reconnect, and Kill Switch
  enforcement during restarts/switches.
- `restore-stat-channels`: recovery point after moving Routing to a top-level
  app section and adding the Stat statistics/channels view to macOS and iOS.

## Recovery Behavior

- Unexpected `disconnected` / reset events start a bounded retry loop only when
  Reconnect after dropped/reset is enabled.
- The retry loop reconnects to the last connected/displayed profile, not a later
  active-profile selection.
- Manual Disconnect, manual Reconnect, profile deletion, and profile switching
  cancel or bypass the dropped/reset retry loop.
- After five failed recovery attempts the failed profile is quarantined, health
  is reassessed, and forced failover may connect a healthier profile. If no
  fallback exists, the app leaves a clear status instead of retrying forever.

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

## Local Checks

```sh
swift build --product SmartVPNMacApp
./scripts/build_ios_device_app.sh
```
