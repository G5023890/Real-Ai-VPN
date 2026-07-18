# Real Ai Router — export-compliance record

Prepared: 18 July 2026  
Product: Real Ai Router 0.98  
iOS bundle identifier: `com.codex.RealAiVPN.iOS`

This folder is a technical record to support the App Store Connect encryption
questionnaire. It is **not** a CCATS, an ERN, a French encryption declaration,
or legal advice. Only the account holder/exporter can make the legal
declaration or submit documentation to a government authority.

## Contents

- `TECHNICAL_ENCRYPTION_DESCRIPTION.md` — the implementation and the accurate
  answers supported by the source tree.
- `APP_STORE_CONNECT_QUESTIONNAIRE.md` — a draft response record for the
  Apple questionnaire.

## Status and next action

The app implements industry-standard encryption outside the Apple operating
system through its VPN components. It must therefore not be declared as an
app that does not use encryption.

Apple's current guidance distinguishes standard algorithms from proprietary,
non-standard algorithms. The former require a French encryption declaration
only when the app is distributed on the French App Store; CCATS is listed for
proprietary/non-standard cryptography. The actual distribution territories and
final declaration remain decisions of the exporter.

For the current TestFlight build, App Store Connect can accept the truthful
questionnaire responses directly. The iOS Info.plist intentionally omits both
the non-exempt-encryption Boolean and any compliance-code key, so that
TestFlight requests those answers for the build rather than validating an
absent code. If Apple's flow later determines that approved documentation is
required, it will supply the exact export-compliance key to add to the
Info.plist.
