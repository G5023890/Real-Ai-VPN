# App Store Connect export-compliance questionnaire — draft

Product: **Real Ai Router**  
Version: **0.98.5 (87)**
Platform: **iOS / TestFlight**

## Proposed factual responses

| Apple subject | Response | Basis |
| --- | --- | --- |
| Uses encryption | Yes | VPN tunnel functionality is present. |
| Encryption limited to Apple's operating systems | No | The app ships the sing-box component. |
| Proprietary or unpublished cryptography | No | The app uses standard, published VPN protocols; it does not implement a proprietary algorithm. |
| Standard encryption algorithms / protocols | Yes | VLESS Reality via sing-box Libbox is supported. |

## Documentation decision

Do **not** attach a made-up CCATS or ERN. Neither exists for this product in
the repository or the prior exports. Apple states that a CCATS is required for
proprietary/non-standard algorithms, which does not describe this app.

If the app is to be offered on the French App Store, obtain and upload the
required French encryption declaration through the appropriate exporter/legal
process. This draft does not replace that declaration.

## Build configuration

The iOS Info.plist deliberately contains neither
`ITSAppUsesNonExemptEncryption` nor `ITSEncryptionExportComplianceCode` for
this TestFlight candidate. This does not declare that the app is unencrypted;
it causes App Store Connect to request the build-level questionnaire, where the
factual responses above are supplied. Do not add an invented compliance code.

## Release operator checklist

1. Open **App Store Connect → Real Ai Router → TestFlight**.
2. Choose the uploaded build and select **Manage** / **Provide Export
   Compliance Information**.
3. Enter the factual responses above.
4. Save the answers. With France excluded from availability, Apple guidance
   does not require a French encryption declaration for this standard-only
   implementation.
5. Only if Apple subsequently displays an actual compliance key, add that
   exact key to the Info.plist and upload a new build.
