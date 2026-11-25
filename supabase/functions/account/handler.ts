// Account actions for Plate or Break It.
//
// The phone calls this function with the player's own sign-in token:
//   {"action":"delete"} -> {"ok": true}
//
// "delete" removes the player's receipt photos from Storage, then the sign-in account.
// Deleting the account removes the player's row, and with it their ratings, check-ins,
// friends and keys (they all cascade from public.players).
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "receipts";

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function admin(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", `Bearer ${SERVICE_KEY}`);
  headers.set("Content-Type", "application/json");
  return fetch(`${SUPABASE_URL}/${path}`, { ...init, headers });
}

/** The player ID in a token's claims. The platform checks the token's signature before this
 *  function runs (functions are deployed with JWT verification on). */
function subject(authorization: string): string | undefined {
  try {
    const claims = JSON.parse(atob(authorization.replace(/^Bearer /, "").split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return claims.role === "authenticated" && typeof claims.sub === "string" ? claims.sub : undefined;
  } catch {
    return undefined;
  }
}

/** The signed-in player, as the sign-in server sees the token (not just its claims).
 *  `gone` is set when the token is genuine but its account was already deleted, so a retry
 *  after a lost answer can still finish. */
async function playerFrom(req: Request): Promise<{ id: string; gone: boolean } | undefined> {
  const authorization = req.headers.get("Authorization");
  if (!authorization) return undefined;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: authorization },
  });
  if (!res.ok) {
    const body = await res.text();
    const id = subject(authorization);
    return body.includes("user_not_found") && id ? { id, gone: true } : undefined;
  }
  const user = await res.json();
  return typeof user?.id === "string" ? { id: user.id, gone: false } : undefined;
}

/** Deletes every file under "<player>/" in the receipts bucket. */
async function deleteReceipts(player: string): Promise<void> {
  // Each pass deletes up to 1000 files; stop if a pass deletes nothing new.
  for (let pass = 0; pass < 20; pass++) {
    const list = await admin(`storage/v1/object/list/${BUCKET}`, {
      method: "POST",
      body: JSON.stringify({ prefix: `${player}/`, limit: 1000, offset: 0 }),
    });
    if (!list.ok) throw new Error(`listing receipts: HTTP ${list.status}`);
    const files = (await list.json() as { name: string }[]).map((file) => `${player}/${file.name}`);
    if (files.length === 0) return;
    const removed = await admin(`storage/v1/object/${BUCKET}`, {
      method: "DELETE",
      body: JSON.stringify({ prefixes: files }),
    });
    if (!removed.ok) throw new Error(`deleting receipts: HTTP ${removed.status}`);
    if ((await removed.json() as unknown[]).length === 0) throw new Error("receipts were not deleted");
  }
  throw new Error("too many receipts to delete");
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json(405, { message: "POST only" });
  let input: Record<string, string>;
  try {
    input = await req.json();
  } catch {
    return json(400, { message: "Bad request" });
  }
  const player = await playerFrom(req);
  if (!player) return json(401, { message: "Sign in first" });

  try {
    switch (input.action) {
      case "delete": {
        await deleteReceipts(player.id);
        if (player.gone) return json(200, { ok: true });
        const res = await admin(`auth/v1/admin/users/${player.id}`, { method: "DELETE" });
        // Already gone counts as done, so a retry after a dropped answer succeeds.
        if (!res.ok && res.status !== 404) return json(502, { message: `deleting the account: HTTP ${res.status}` });
        return json(200, { ok: true });
      }
      default:
        return json(400, { message: "Unknown action" });
    }
  } catch (error) {
    return json(502, { message: (error as Error).message });
  }
}
