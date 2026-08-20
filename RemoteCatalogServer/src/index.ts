export interface Env {
  GITHUB_REPOSITORY: string;
  GITHUB_BRANCH?: string;
  CATALOG_USER_PATH?: string;
  CATALOG_ADMIN_PATH?: string;
  GITHUB_TOKEN: string;
  AUTH_SECRET: string;
  ADMIN_ACCESS_KEY: string;
}

type Role = "user" | "admin";
type AccessTokenPayload = { sub: string; role: Role; exp: number };
const encoder = new TextEncoder();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
    const match = url.pathname.match(/^\/v1\/catalogs\/(user|admin)$/);
    if (request.method !== "GET" || !match) return json({ error: "not_found" }, 404);
    const requestedRole = match[1] as Role;
    const authorization = await authorize(request, requestedRole, env);
    if (!authorization.allowed) return json({ error: authorization.status === 403 ? "forbidden" : "unauthorized" }, authorization.status);

    const path = requestedRole === "admin"
      ? env.CATALOG_ADMIN_PATH ?? "catalogs/admin.signed.json"
      : env.CATALOG_USER_PATH ?? "catalogs/user.signed.json";
    const catalog = await loadPrivateGitHubFile(env, path);
    if (catalog instanceof Response) return catalog;
    const etag = `W/\"${catalog.sha}\"`;
    if (request.headers.get("If-None-Match") === etag) {
      return new Response(null, { status: 304, headers: { ETag: etag, "Cache-Control": "no-store" } });
    }
    return new Response(catalog.content, {
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "ETag": etag, "X-Content-Type-Options": "nosniff" }
    });
  }
};

async function loadPrivateGitHubFile(env: Env, path: string): Promise<{ content: string; sha: string } | Response> {
  const branch = encodeURIComponent(env.GITHUB_BRANCH ?? "main");
  const normalizedPath = path.split("/").map(encodeURIComponent).join("/");
  const response = await fetch(`https://api.github.com/repos/${env.GITHUB_REPOSITORY}/contents/${normalizedPath}?ref=${branch}`, {
    headers: { "Accept": "application/vnd.github+json", "Authorization": `Bearer ${env.GITHUB_TOKEN}`, "User-Agent": "real-ai-router-catalog-worker", "X-GitHub-Api-Version": "2022-11-28" }
  });
  if (!response.ok) return json({ error: "catalog_unavailable" }, 503);
  const file = await response.json() as { content?: string; encoding?: string; sha?: string };
  if (file.encoding !== "base64" || !file.content || !file.sha) return json({ error: "invalid_catalog_source" }, 503);
  try { return { content: atob(file.content.replace(/\n/g, "")), sha: file.sha }; }
  catch { return json({ error: "invalid_catalog_source" }, 503); }
}

async function authorize(request: Request, requestedRole: Role, env: Env): Promise<{ allowed: boolean; status: 401 | 403 }> {
  const value = request.headers.get("Authorization");
  // The User catalog is intentionally public. It contains only the profiles
  // intended for every app installation and never needs a client credential.
  if (requestedRole === "user" && !value) return { allowed: true, status: 401 };
  if (requestedRole === "admin" && value?.startsWith("Bearer ") && await securelyMatchesAdminKey(value.slice(7), env)) {
    return { allowed: true, status: 401 };
  }
  const token = await authenticate(value, env.AUTH_SECRET);
  if (!token) return { allowed: false, status: 401 };
  return canRead(token.role, requestedRole)
    ? { allowed: true, status: 401 }
    : { allowed: false, status: 403 };
}

async function authenticate(value: string | null, secret: string): Promise<AccessTokenPayload | null> {
  if (!value?.startsWith("Bearer ")) return null;
  const [encodedPayload, encodedSignature, extra] = value.slice(7).split(".");
  if (!encodedPayload || !encodedSignature || extra) return null;
  try {
    const key = await crypto.subtle.importKey("raw", base64URLDecode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const valid = await crypto.subtle.verify("HMAC", key, base64URLDecode(encodedSignature), encoder.encode(encodedPayload));
    if (!valid) return null;
    const payload = JSON.parse(new TextDecoder().decode(base64URLDecode(encodedPayload))) as AccessTokenPayload;
    if ((payload.role !== "user" && payload.role !== "admin") || !payload.sub || !Number.isFinite(payload.exp) || payload.exp <= Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch { return null; }
}

async function securelyMatchesAdminKey(candidate: string, env: Env): Promise<boolean> {
  const [candidateDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(candidate)),
    crypto.subtle.digest("SHA-256", encoder.encode(env.ADMIN_ACCESS_KEY))
  ]);
  const left = new Uint8Array(candidateDigest);
  const right = new Uint8Array(expectedDigest);
  let difference = left.length ^ right.length;
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function canRead(tokenRole: Role, requestedRole: Role): boolean { return tokenRole === "admin" || tokenRole === requestedRole; }
function base64URLDecode(value: string): ArrayBuffer {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const decoded = atob(padded);
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded.charCodeAt(index);
  return bytes.buffer;
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });
}
