# Real Ai Router 0.98.5 (87)

- VLESS Reality is the only shipped tunnel runtime; WireGuard userspace and
  `libwg-go` are excluded from both iOS and macOS products.
- Fixed VLESS/Xray JSON decoding in signed remote User and Admin catalogs.
- Added automatic User catalog synchronization on first launch for iOS and macOS.
- Admin synchronization now validates the password entered in the current dialog
  against the published SHA-256 access record.
- Added reliable refresh of the catalog access record after an Admin password change.
- Added non-destructive migration of profiles from pre-0.98 Keychain storage.
- Fixed stale catalog signing-key bootstrap data so clean installs verify the
  current signed GitHub catalog.
- Added macOS Catalog Manager as a separate local administration utility; it is
  not part of the TestFlight app.
