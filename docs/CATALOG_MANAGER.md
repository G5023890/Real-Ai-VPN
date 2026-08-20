# Catalog Manager

`Real Ai Router Catalog Manager.app` keeps the User and Admin VLESS catalogs
up to date in `G5023890/Real-Ai-VPN-Catalog`.

## First publish

1. Start the manager from `/Applications` and copy the displayed **Ed25519
   public key**.
2. In Real Ai Router open **VPN Profiles → Remote Catalogs**, paste that key,
   and save the configuration. Do this before publishing a catalog signed by a
   newly created Manager key.
3. Ensure the GitHub CLI is authorized on this Mac: `gh auth status`.

The private signing key is generated once and stored only in this Mac's
Keychain. It is never committed to GitHub.

## Updating profiles

1. Select **User** or **Admin**.
2. Click **Import configuration files…** and choose VLESS/Xray JSON files.
   Example source folders are:
   - `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/VPN/User Conf`
   - `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/VPN/Admin conf`
3. Remove unwanted entries with **Remove selected**.
4. Click **Publish User** or **Publish Admin**.
5. In Real Ai Router use **Sync User** or **Unlock & Sync Admin**.

Publishing changes only the chosen signed catalog. Manually imported VPN
profiles in Real Ai Router are not affected.
