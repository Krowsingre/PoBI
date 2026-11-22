// App Attest for Plate or Break It.
//
// The phone calls this function with the player's own sign-in token:
//   {"action":"challenge"}                               -> {"challenge": "..."}
//   {"action":"register","keyId","attestation","challenge"} -> {"ok": true}
//   {"action":"submit","keyId","assertion","table","body"}  -> the database's own answer
//
// "submit" checks the assertion over the exact body text, then passes the rating or
// check-in to the database as the player, adding a header only this function knows.
// The database marks such rows attested (see the app_attest migration).
import { verifyAssertion, verifyAttestation } from "npm:node-app-attest@2.2.0";
import { Buffer } from "node:buffer";

const BUNDLE_ID = "com.krowsingre.pobi";
const TEAM_ID = (Deno.env.get("APPLE_TEAM_ID") ?? "").trim();
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHALLENGE_MINUTES = 10;
const TABLES = new Set(["ratings", "check_ins"]);

let secret: string | undefined;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

/** Calls the database's REST API with the service key. */
async function admin(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", `Bearer ${SERVICE_KEY}`);
  headers.set("Content-Type", "application/json");
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { ...init, headers });
}

async function sharedSecret(): Promise<string> {
  if (secret) return secret;
  const res = await admin("attest_settings?select=secret");
  if (!res.ok) throw new Error(`settings: HTTP ${res.status}`);
  secret = (await res.json())[0].secret as string;
  return secret;
}

async function hmac(text: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(await sharedSecret()), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return Buffer.from(mac).toString("base64url");
}

/** A challenge is "<time>.<mac of player and time>", so nothing needs to be stored for it. */
async function makeChallenge(player: string): Promise<string> {
  const now = Date.now().toString();
  return `${now}.${await hmac(`${player}.${now}`)}`;
}

async function challengeIsValid(player: string, challenge: string): Promise<boolean> {
  const [time, mac] = challenge.split(".");
  const age = Date.now() - Number(time);
  if (!time || !mac || !(age >= 0 && age < CHALLENGE_MINUTES * 60_000)) return false;
  return mac === await hmac(`${player}.${time}`);
}

/** The player's ID from their token. The platform has already checked the token's signature. */
function playerFrom(req: Request): string | undefined {
  const token = req.headers.get("Authorization")?.replace(/^Bearer /, "");
  try {
    const claims = JSON.parse(Buffer.from(token!.split(".")[1], "base64url").toString());
    return claims.role === "authenticated" ? claims.sub : undefined;
  } catch {
    return undefined;
  }
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json(405, { message: "POST only" });
  if (!TEAM_ID) return json(500, { message: "APPLE_TEAM_ID is not set" });
  const player = playerFrom(req);
  if (!player) return json(401, { message: "Sign in first" });
  let input: Record<string, string>;
  try {
    input = await req.json();
  } catch {
    return json(400, { message: "Bad request" });
  }

  try {
    switch (input.action) {
      case "challenge":
        return json(200, { challenge: await makeChallenge(player) });

      case "register": {
        if (!(await challengeIsValid(player, input.challenge ?? ""))) {
          return json(400, { code: "challenge", message: "The challenge expired. Try again." });
        }
        const result = verifyAttestation({
          attestation: Buffer.from(input.attestation ?? "", "base64"),
          challenge: input.challenge,
          keyId: input.keyId,
          bundleIdentifier: BUNDLE_ID,
          teamIdentifier: TEAM_ID,
          // TestFlight and App Store builds use production; builds run from Xcode use development.
          allowDevelopmentEnvironment: true,
        });
        const res = await admin("app_keys", {
          method: "POST",
          headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
          body: JSON.stringify({
            key_id: result.keyId, player_id: player, public_key: result.publicKey, environment: result.environment,
          }),
        });
        if (!res.ok) return json(res.status, { message: await res.text() });
        return json(200, { ok: true, environment: result.environment });
      }

      case "submit": {
        if (!TABLES.has(input.table)) return json(400, { message: "Unknown table" });
        const keys = await (await admin(
          `app_keys?select=public_key,sign_count&key_id=eq.${encodeURIComponent(input.keyId ?? "")}&player_id=eq.${player}`,
        )).json();
        if (!Array.isArray(keys) || keys.length !== 1) {
          return json(404, { code: "unknown_key", message: "This phone isn't verified yet." });
        }
        const { signCount } = verifyAssertion({
          assertion: Buffer.from(input.assertion ?? "", "base64"),
          payload: input.body,
          publicKey: keys[0].public_key,
          bundleIdentifier: BUNDLE_ID,
          teamIdentifier: TEAM_ID,
          signCount: Number(keys[0].sign_count),
        });
        // Move the counter forward only if nobody else did first, so an assertion can't be used twice.
        const moved = await admin(
          `app_keys?key_id=eq.${encodeURIComponent(input.keyId)}&sign_count=eq.${keys[0].sign_count}`,
          {
            method: "PATCH",
            headers: { Prefer: "return=representation" },
            body: JSON.stringify({ sign_count: signCount, last_used_at: new Date().toISOString() }),
          },
        );
        if (!moved.ok || (await moved.json()).length !== 1) {
          return json(409, { code: "replayed", message: "That request was already used." });
        }
        const res = await fetch(`${SUPABASE_URL}/rest/v1/${input.table}`, {
          method: "POST",
          headers: {
            apikey: ANON_KEY,
            Authorization: req.headers.get("Authorization")!,
            "Content-Type": "application/json",
            Prefer: "resolution=ignore-duplicates,return=minimal",
            "x-pobi-attest": await sharedSecret(),
          },
          body: input.body,
        });
        return new Response(await res.text(), {
          status: res.status,
          headers: { "Content-Type": res.headers.get("Content-Type") ?? "application/json" },
        });
      }

      default:
        return json(400, { message: "Unknown action" });
    }
  } catch (error) {
    // A failed check from the App Attest library: the app makes a new key and tries again.
    return json(403, { code: "attest_failed", message: (error as Error).message });
  }
}
