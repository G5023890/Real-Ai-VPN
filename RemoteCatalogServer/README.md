# Real Ai Router GitHub catalog

The current app reads signed catalog files **directly from GitHub**. Cloudflare,
a Worker, `GITHUB_TOKEN`, and `AUTH_SECRET` are not required. The source
repository is `G5023890/Real-Ai-VPN-Catalog`; it must be public for devices to
download it without GitHub credentials.

`User` is public by default. `Admin` uses a password prompt in the app. The
repository contains only a SHA-256 hash of that password, so the password is
not published. This is an interface-level convenience gate, not protection for
the Admin configuration: everyone who can read a public repository can also
download its files. The Ed25519 signature remains the integrity protection.

## One-time catalog setup

1. In `G5023890/Real-Ai-VPN-Catalog`, create a `catalogs` folder. Copy the two
   manifest templates in this directory to `catalogs/user.manifest.json` and
   `catalogs/admin.manifest.json`. Place actual VLESS records there.
2. Generate a signing pair on an administrator Mac, outside this app repository:

   ```sh
   swift scripts/generate_signing_key.swift ~/Secure/real-ai-router-catalog
   ```

   Keep `catalog-signing-private.key` offline. Paste its public counterpart into the app's **Remote Catalogs** screen.
3. Sign each manifest after every change. Commit the resulting signed files to
   the public catalog repository:

   ```sh
   swift scripts/sign_catalog.swift catalogs/user.manifest.json ~/Secure/real-ai-router-catalog/catalog-signing-private.key catalogs/user.signed.json
   swift scripts/sign_catalog.swift catalogs/admin.manifest.json ~/Secure/real-ai-router-catalog/catalog-signing-private.key catalogs/admin.signed.json
   ```

4. Choose an Admin password. Generate a hash without placing the password in
   shell history, then put the result in `catalogs/admin-access.json` using
   `catalogs/admin-access.template.json`:

   ```sh
   read -s "ADMIN_PASSWORD?Choose Admin password: "; echo
   printf %s "$ADMIN_PASSWORD" | shasum -a 256 | awk '{print $1}'
   unset ADMIN_PASSWORD
   ```

   Enter that same password in the app's **Admin password** field and press
   **Save**, then **Unlock & Sync Admin**.

5. In the app’s **Remote Catalogs** screen enter:

   - Catalog ID: `primary`
   - GitHub catalog URL: `https://raw.githubusercontent.com/G5023890/Real-Ai-VPN-Catalog/main/catalogs`
   - Ed25519 public key: the public key from step 2.

### Legacy Worker

The `src/`, `wrangler.toml`, and Node scripts remain here only as a historical
deployment reference. They are not used by the current app and no Cloudflare
configuration is required.

## Manifest records

Each profile has this shape. The shipped runtime supports `VLESS Reality`;
`WireGuard Config` records remain parseable for compatibility while the
WireGuard runtime is deferred. Stable remote `id` values are retained across
revisions.

```json
{
  "id": "se-stockholm-1",
  "displayName": "Stockholm",
  "kind": "WireGuard Config",
  "regionCode": "SE",
  "endpointHost": "se.example.net",
  "config": "[Interface]..."
}
```

The historical Worker never signs or alters a configuration. It is not used by
the current direct-GitHub flow. A valid catalog still needs an app-verified
Ed25519 signature. Removing a record from a manifest removes only the matching
managed record; manually imported local profiles are untouched.
