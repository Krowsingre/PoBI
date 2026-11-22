import { test } from "node:test";
import assert from "node:assert/strict";
import { replay } from "./replay.ts";

const places = [{ id: "a", area: "X" }, { id: "b", area: "X" }];
const players = [{ id: "p1", team: "team1" }, { id: "p2", team: "team2" }];

test("a check-in claims a rated place", () => {
  const t = Date.parse("2026-11-10T15:00:00Z");
  const out = replay(players,
    [{ player_id: "p1", place_id: "a", verdict: "plateIt", stars: 2, counted_at: new Date(t).toISOString() }],
    [{ player_id: "p1", place_id: "a", checked_at: new Date(t + 60_000).toISOString() }],
    places, t + 120_000);
  assert.equal(out.places.get("a")?.team, "team1");
});

test("the area goes to the team with the most new ratings at month end", () => {
  const t = Date.parse("2026-11-10T15:00:00Z");
  const out = replay(players, [
    { player_id: "p1", place_id: "a", verdict: "plateIt", stars: 2, counted_at: new Date(t).toISOString() },
    { player_id: "p1", place_id: "b", verdict: "breakIt", stars: 1, counted_at: new Date(t + 1000).toISOString() },
    { player_id: "p2", place_id: "a", verdict: "plateIt", stars: 3, counted_at: new Date(t + 2000).toISOString() },
  ], [], places, Date.parse("2026-12-02T12:00:00Z"));
  assert.equal(out.areas.get("X"), "team1");
});

test("before month end nobody owns the area yet", () => {
  const t = Date.parse("2026-11-10T15:00:00Z");
  const out = replay(players,
    [{ player_id: "p1", place_id: "a", verdict: "plateIt", stars: 2, counted_at: new Date(t).toISOString() }],
    [], places, t + 1000);
  assert.equal(out.areas.size, 0);
});

test("rows the rules reject are counted, not fatal", () => {
  const t = Date.parse("2026-11-10T15:00:00Z");
  const out = replay(players, [],
    [{ player_id: "p1", place_id: "a", checked_at: new Date(t).toISOString() }], places, t + 1000);
  assert.equal(out.skipped["checkIn:not_rated_and_area_not_owned"], 1);
});
