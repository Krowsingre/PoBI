// Game runner: reads ratings and check-ins from Supabase, replays them through the
// rules engine (engine/), and writes area and place owners back for the app's map.
// Runs on a schedule from .github/workflows/runner.yml with the service role key.
import { cellToBoundary } from "h3-js";
import { replay, type CheckInRow, type PlaceRow, type PlayerRow, type RatingRow } from "./replay.ts";

const base = process.env.SUPABASE_URL!.replace(/\/$/, "");
const key = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const headers = { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };

async function getAll<T>(path: string): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += 1000) {
    const res = await fetch(`${base}/rest/v1/${path}`, {
      headers: { ...headers, Range: `${from}-${from + 999}` },
    });
    if (!res.ok) throw new Error(`GET ${path.split("?")[0]}: HTTP ${res.status} ${await res.text()}`);
    const page = (await res.json()) as T[];
    out.push(...page);
    if (page.length < 1000) return out;
  }
}

async function send(method: string, path: string, body?: unknown): Promise<void> {
  const res = await fetch(`${base}/rest/v1/${path}`, {
    method, headers: { ...headers, Prefer: "return=minimal" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${method} ${path.split("?")[0]}: HTTP ${res.status} ${await res.text()}`);
}

const now = Date.now();
const players = await getAll<PlayerRow>("players?select=id,team");
const ratings = await getAll<RatingRow>(
  "ratings?select=player_id,place_id,verdict,stars,counted_at&counted_at=not.is.null&rejected=is.false&order=counted_at",
);
const checkIns = await getAll<CheckInRow>("check_ins?select=player_id,place_id,checked_at&order=checked_at");

const ids = [...new Set([...ratings, ...checkIns].map((r) => r.place_id))];
const places: PlaceRow[] = [];
for (let i = 0; i < ids.length; i += 150) {
  const list = ids.slice(i, i + 150).map((id) => `"${id}"`).join(",");
  places.push(...(await getAll<PlaceRow>(`places?select=id,area&id=in.(${list})`)));
}

const result = replay(players, ratings, checkIns, places, now);

const areaRows = [...result.areas].map(([area, team]) => ({
  area, team, boundary: cellToBoundary(area).map(([lat, lon]) => [round(lat), round(lon)]),
}));
const placeRows = [...result.places].map(([place_id, v]) => ({ place_id, team: v.team, area: v.area }));

// Swap in the new result in one transaction (see replace_owners in the migrations).
await send("POST", "rpc/replace_owners", {
  areas: areaRows, places: placeRows,
  run: { ratings: ratings.length, check_ins: checkIns.length, skipped: result.skipped },
});

// Receipt photos are kept 30 days after review, so a player can contest it, then deleted (D20).
const cutoff = new Date(now - 30 * 24 * 60 * 60 * 1000).toISOString();
const expired = await getAll<{ id: string; player_id: string }>(
  `ratings?select=id,player_id&receipt_photo=is.true&photo_deleted_at=is.null&reviewed_at=lt.${cutoff}`,
);
for (const r of expired) {
  const res = await fetch(`${base}/storage/v1/object/receipts/${r.player_id}/${r.id}.jpg`, { method: "DELETE", headers });
  if (!res.ok && res.status !== 404 && res.status !== 400) {
    throw new Error(`Deleting a receipt photo: HTTP ${res.status} ${await res.text()}`);
  }
  await send("PATCH", `ratings?id=eq.${r.id}`, { photo_deleted_at: new Date().toISOString() });
}
if (expired.length) console.log(`Deleted ${expired.length} receipt photos reviewed over 30 days ago.`);

console.log(`Replayed ${ratings.length} ratings and ${checkIns.length} check-ins from ${players.length} players.`);
console.log(`Owned: ${areaRows.length} areas, ${placeRows.length} places. Skipped: ${JSON.stringify(result.skipped)}`);

function round(x: number): number {
  return Math.round(x * 1e6) / 1e6;
}
