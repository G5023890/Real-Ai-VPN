import { createHmac, randomBytes } from "node:crypto";
const [subject, role, lifetimeDays = "90"] = process.argv.slice(2);
const secret = process.env.REMOTE_CATALOG_AUTH_SECRET;
if (!secret || !subject || !["user", "admin"].includes(role)) {
  console.error("Usage: REMOTE_CATALOG_AUTH_SECRET=<base64url-secret> npm run issue-token -- <subject> <user|admin> [days]");
  process.exit(1);
}
const days = Number(lifetimeDays);
if (!Number.isFinite(days) || days <= 0 || days > 365) { console.error("Lifetime must be between 1 and 365 days."); process.exit(1); }
const encode = (value) => Buffer.from(value).toString("base64url");
const payload = encode(JSON.stringify({ sub: subject, role, exp: Math.floor(Date.now() / 1000) + Math.floor(days * 86400), nonce: randomBytes(8).toString("hex") }));
const signature = createHmac("sha256", Buffer.from(secret, "base64url")).update(payload).digest("base64url");
console.log(`${payload}.${signature}`);
