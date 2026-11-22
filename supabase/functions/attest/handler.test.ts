// Run with: deno test --allow-env supabase/functions/attest/handler.test.ts
// The database is faked; Apple's attestation itself can only be tested on a real iPhone.
import { assertEquals } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { createHash, createSign, generateKeyPairSync } from "node:crypto";
import { encode } from "npm:cbor2@2.4.2";

Deno.env.set("APPLE_TEAM_ID", "TEAM123456");
Deno.env.set("SUPABASE_URL", "https://db.test");
Deno.env.set("SUPABASE_ANON_KEY", "anon");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service");
const { handle } = await import("./handler.ts");

const player = "11111111-1111-1111-1111-111111111111";
const token = `x.${Buffer.from(JSON.stringify({ sub: player, role: "authenticated" })).toString("base64url")}.y`;
const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const key = { public_key: publicKey.export({ type: "spki", format: "pem" }), sign_count: 0 };
const inserted: { headers: Headers; body: string }[] = [];

globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
  const url = String(input);
  const headers = new Headers(init.headers);
  if (url.includes("attest_settings")) return Response.json([{ secret: "s3cret" }]);
  if (url.includes("app_keys") && init.method === "PATCH") {
    const expected = Number(new URL(url).searchParams.get("sign_count")!.replace("eq.", ""));
    if (expected !== key.sign_count) return Response.json([]);
    key.sign_count = JSON.parse(String(init.body)).sign_count;
    return Response.json([key]);
  }
  if (url.includes("app_keys")) return Response.json(url.includes("key_id=eq.k1") ? [key] : []);
  if (url.endsWith("/rest/v1/ratings")) {
    inserted.push({ headers, body: String(init.body) });
    return new Response(null, { status: 201 });
  }
  return new Response("unexpected " + url, { status: 500 });
}) as typeof fetch;

function call(body: unknown): Promise<Response> {
  return handle(new Request("https://fn.test", {
    method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body),
  }));
}

function assertion(payload: string, counter: number): string {
  const authData = Buffer.alloc(37);
  createHash("sha256").update("TEAM123456.com.krowsingre.pobi").digest().copy(authData, 0);
  authData.writeUInt32BE(counter, 33);
  const nonce = createHash("sha256")
    .update(Buffer.concat([authData, createHash("sha256").update(payload).digest()])).digest();
  const signature = createSign("SHA256").update(nonce).sign(privateKey);
  return Buffer.from(encode({ signature: new Uint8Array(signature), authenticatorData: new Uint8Array(authData) })).toString("base64");
}

Deno.test("a challenge is only valid for the player it was made for", async () => {
  const { challenge } = await (await call({ action: "challenge" })).json();
  const bad = await call({ action: "register", keyId: "k", attestation: "", challenge: challenge + "x" });
  assertEquals(bad.status, 400);
  const garbage = await call({ action: "register", keyId: "k", attestation: "AAAA", challenge });
  assertEquals(garbage.status, 403); // passed the challenge, failed Apple's check
});

Deno.test("a signed rating goes to the database with the secret header", async () => {
  const body = JSON.stringify({ id: "r1", place_id: "p1" });
  const res = await call({ action: "submit", table: "ratings", keyId: "k1", body, assertion: assertion(body, 1) });
  assertEquals(res.status, 201);
  assertEquals(inserted.at(-1)?.headers.get("x-pobi-attest"), "s3cret");
  assertEquals(inserted.at(-1)?.headers.get("Authorization"), `Bearer ${token}`);
  assertEquals(inserted.at(-1)?.body, body);
});

Deno.test("replays, edited bodies, unknown keys and other tables are refused", async () => {
  const body = JSON.stringify({ id: "r2" });
  const signed = assertion(body, 2);
  assertEquals((await call({ action: "submit", table: "ratings", keyId: "k1", body, assertion: signed })).status, 201);
  assertEquals((await call({ action: "submit", table: "ratings", keyId: "k1", body, assertion: signed })).status, 403);
  const edited = JSON.stringify({ id: "r3" });
  assertEquals((await call({ action: "submit", table: "ratings", keyId: "k1", body: edited, assertion: assertion(body, 3) })).status, 403);
  assertEquals((await call({ action: "submit", table: "ratings", keyId: "nope", body, assertion: assertion(body, 4) })).status, 404);
  assertEquals((await call({ action: "submit", table: "players", keyId: "k1", body, assertion: assertion(body, 5) })).status, 400);
  assertEquals(inserted.length, 2);
});
