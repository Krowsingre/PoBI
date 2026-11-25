// Run with: deno test --allow-env supabase/functions/account/handler.test.ts
// The sign-in server and Storage are faked.
import { assertEquals } from "jsr:@std/assert@1";

Deno.env.set("SUPABASE_URL", "https://db.test");
Deno.env.set("SUPABASE_ANON_KEY", "anon");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service");
const { handle } = await import("./handler.ts");

const player = "11111111-1111-1111-1111-111111111111";
let files: string[] = [];
let users: string[] = [];
const calls: string[] = [];

globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
  const url = String(input);
  const headers = new Headers(init.headers);
  calls.push(`${init.method ?? "GET"} ${url.replace("https://db.test/", "")}`);
  if (url.endsWith("/auth/v1/user")) {
    return headers.get("Authorization") === "Bearer good" ? Response.json({ id: player }) : new Response(null, { status: 401 });
  }
  if (headers.get("Authorization") !== "Bearer service") return new Response(null, { status: 403 });
  if (url.endsWith("/storage/v1/object/list/receipts")) {
    const { prefix } = JSON.parse(String(init.body));
    return Response.json(files.filter((f) => f.startsWith(prefix)).map((f) => ({ name: f.slice(prefix.length) })));
  }
  if (url.endsWith("/storage/v1/object/receipts") && init.method === "DELETE") {
    const { prefixes } = JSON.parse(String(init.body)) as { prefixes: string[] };
    const gone = files.filter((f) => prefixes.includes(f));
    files = files.filter((f) => !prefixes.includes(f));
    return Response.json(gone.map((name) => ({ name })));
  }
  if (url.includes("/auth/v1/admin/users/") && init.method === "DELETE") {
    const id = url.split("/").pop()!;
    if (!users.includes(id)) return new Response(null, { status: 404 });
    users = users.filter((u) => u !== id);
    return Response.json({});
  }
  return new Response("unexpected " + url, { status: 500 });
}) as typeof fetch;

function call(body: unknown, token = "good"): Promise<Response> {
  return handle(new Request("https://fn.test", {
    method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body),
  }));
}

Deno.test("delete removes only the player's receipts, then the account", async () => {
  files = [`${player}/a.jpg`, `${player}/b.jpg`, "22222222-2222-2222-2222-222222222222/c.jpg"];
  users = [player, "22222222-2222-2222-2222-222222222222"];
  calls.length = 0;
  const res = await call({ action: "delete" });
  assertEquals(res.status, 200);
  assertEquals(files, ["22222222-2222-2222-2222-222222222222/c.jpg"]);
  assertEquals(users, ["22222222-2222-2222-2222-222222222222"]);
  assertEquals(calls.at(-1), `DELETE auth/v1/admin/users/${player}`);
});

Deno.test("deleting twice still succeeds", async () => {
  const res = await call({ action: "delete" });
  assertEquals(res.status, 200);
});

Deno.test("a bad token deletes nothing", async () => {
  files = [`${player}/a.jpg`];
  users = [player];
  const res = await call({ action: "delete" }, "forged");
  assertEquals(res.status, 401);
  assertEquals(files.length, 1);
  assertEquals(users.length, 1);
});
