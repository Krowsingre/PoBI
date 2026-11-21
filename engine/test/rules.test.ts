import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { bar } from "../src/engine.ts";
import { mustOk, newGame, players, t } from "./helpers.ts";

describe("thresholds", () => {
  test("3x the owner's count, 0 needs 1 (D2, D6)", () => {
    assert.equal(bar(3, 0), 1);
    assert.equal(bar(3, 1), 3);
    assert.equal(bar(3, 10), 30);
  });
  test("fractions round up (K2)", () => {
    assert.equal(bar(1.5, 1), 2);
    assert.equal(bar(1.5, 3), 5);
    assert.equal(bar(2.5, 3), 8);
    assert.equal(bar(1.5, 0), 1);
  });
});

describe("ratings", () => {
  test("one original rating per player per establishment; all-time totals kept", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("p", "team1");
    mustOk(g.rate("p", "e1", "plate", 3, t(2026, 11, 2)));
    assert.deepEqual(g.rate("p", "e1", "break", 1, t(2026, 11, 3)), { ok: false, reason: "already_rated" });
    assert.equal(g.allTimeRatings.get("team1"), 1);
  });
  test("a rating does not claim the establishment; only check-ins do", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("p", "team1");
    mustOk(g.rate("p", "e1", "break", 3, t(2026, 11, 2)));
    assert.equal(g.establishments.get("e1")!.owner, null);
  });
});

describe("check-ins (D10)", () => {
  test("once a day where you've rated", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("p", "team1");
    mustOk(g.rate("p", "e1", "plate", 2, t(2026, 11, 2, 9)));
    mustOk(g.checkIn("p", "e1", t(2026, 11, 2, 10)));
    assert.deepEqual(g.checkIn("p", "e1", t(2026, 11, 2, 22)), { ok: false, reason: "already_checked_in_today" });
    mustOk(g.checkIn("p", "e1", t(2026, 11, 3, 8)));
  });

  test("unrated places: only in an area your team owns, once per Sunday-start week, no reset at month change", () => {
    const g = newGame();
    for (const e of ["e1", "e2"]) g.addEstablishment(e, "a1");
    g.addPlayer("owner", "team1");
    g.addPlayer("ally", "team1");
    g.addPlayer("rival", "team2");
    mustOk(g.rate("owner", "e1", "plate", 1, t(2026, 11, 10)));
    // Before the area is owned, nobody can check in at a place they haven't rated.
    assert.deepEqual(g.checkIn("ally", "e2", t(2026, 11, 20)), { ok: false, reason: "not_rated_and_area_not_owned" });
    g.advanceTo(t(2026, 12, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1");

    mustOk(g.checkIn("ally", "e2", t(2026, 12, 2))); // Wednesday
    assert.deepEqual(g.checkIn("ally", "e2", t(2026, 12, 3)), { ok: false, reason: "weekly_check_in_used" });
    mustOk(g.checkIn("ally", "e2", t(2026, 12, 6))); // Sunday: new week
    assert.deepEqual(g.checkIn("rival", "e2", t(2026, 12, 6)), { ok: false, reason: "not_rated_and_area_not_owned" });

    // Week of Sunday Dec 27 runs into January: still one check-in.
    mustOk(g.checkIn("ally", "e2", t(2026, 12, 30)));
    assert.deepEqual(g.checkIn("ally", "e2", t(2027, 1, 2)), { ok: false, reason: "weekly_check_in_used" });
  });
});

describe("establishments: check-ins at any time (D7)", () => {
  test("first check-in claims; stealing needs 3x the owner's check-ins", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("a", "team1");
    const bs = players(g, "team2", 3);
    mustOk(g.rate("a", "e1", "plate", 3, t(2026, 11, 2)));
    mustOk(g.checkIn("a", "e1", t(2026, 11, 2)));
    assert.equal(g.establishments.get("e1")!.owner, "team1");
    for (const [i, b] of bs.entries()) {
      mustOk(g.rate(b, "e1", "break", 2, t(2026, 11, 3, 10 + i)));
      mustOk(g.checkIn(b, "e1", t(2026, 11, 3, 10 + i)));
      assert.equal(g.establishments.get("e1")!.owner, i < 2 ? "team1" : "team2");
    }
  });

  test("embre's example: 102 check-ins hold against 75", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    const as = players(g, "team1", 100);
    const bs = players(g, "team2", 75);
    for (const p of [...as, ...bs]) mustOk(g.rate(p, "e1", "plate", 1, t(2026, 11, 1, 8)));
    for (const p of as) mustOk(g.checkIn(p, "e1", t(2026, 11, 1, 12)));
    mustOk(g.checkIn(as[0], "e1", t(2026, 11, 2, 12)));
    mustOk(g.checkIn(as[1], "e1", t(2026, 11, 2, 12)));
    for (const p of bs) mustOk(g.checkIn(p, "e1", t(2026, 11, 2, 13)));
    assert.equal(g.establishments.get("e1")!.owner, "team1");
  });

  test("owner's defense uses the last 30 days; challenger's count starts at 0 each month (QA)", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("a", "team1");
    const bs = players(g, "team2", 9);
    mustOk(g.rate("a", "e1", "plate", 3, t(2026, 11, 27)));
    for (const d of [28, 29, 30]) mustOk(g.checkIn("a", "e1", t(2026, 11, d)));
    for (const b of bs) mustOk(g.rate(b, "e1", "plate", 1, t(2026, 11, 30)));
    // A November check-in by team2 doesn't carry into December.
    mustOk(g.checkIn(bs[0], "e1", t(2026, 11, 30, 18)));
    for (const [i, b] of bs.entries()) {
      if (i === 0) continue;
      mustOk(g.checkIn(b, "e1", t(2026, 12, 1, 10)));
    }
    // 8 December check-ins against the owner's 3 in 30 days (needs 9).
    assert.equal(g.establishments.get("e1")!.owner, "team1");
    mustOk(g.checkIn(bs[0], "e1", t(2026, 12, 1, 11)));
    assert.equal(g.establishments.get("e1")!.owner, "team2");
  });

  test("an owner with no check-ins in 30 days loses to a single check-in", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("a", "team1");
    g.addPlayer("b", "team2");
    mustOk(g.rate("a", "e1", "plate", 3, t(2026, 11, 2)));
    mustOk(g.checkIn("a", "e1", t(2026, 11, 2)));
    mustOk(g.rate("b", "e1", "plate", 1, t(2026, 12, 5)));
    mustOk(g.checkIn("b", "e1", t(2026, 12, 5)));
    assert.equal(g.establishments.get("e1")!.owner, "team2");
  });
});

describe("areas: new ratings at month end (D7)", () => {
  test("a lone player rating one of five places claims the area", () => {
    const g = newGame();
    for (let i = 1; i <= 5; i++) g.addEstablishment(`e${i}`, "a1");
    g.addPlayer("solo", "team1");
    mustOk(g.rate("solo", "e1", "plate", 2, t(2026, 11, 10)));
    g.advanceTo(t(2026, 11, 30, 23, 59));
    assert.equal(g.areas.get("a1")!.owner, null);
    g.advanceTo(t(2026, 12, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1");
  });

  test("a tie for an unowned area leaves it unowned (not yet decided)", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("a", "team1");
    g.addPlayer("b", "team2");
    mustOk(g.rate("a", "e1", "plate", 2, t(2026, 11, 10)));
    mustOk(g.rate("b", "e1", "plate", 2, t(2026, 11, 11)));
    g.advanceTo(t(2026, 12, 1, 1));
    assert.equal(g.areas.get("a1")!.owner, null);
  });

  function ownedArea() {
    const g = newGame();
    for (let i = 1; i <= 6; i++) g.addEstablishment(`e${i}`, "a1");
    g.addPlayer("founder", "team1");
    mustOk(g.rate("founder", "e1", "plate", 2, t(2026, 11, 10)));
    g.advanceTo(t(2026, 12, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1");
    return g;
  }

  test("taking an owned area needs 3x the owner's new ratings that month (D2)", () => {
    const g = ownedArea();
    const as = players(g, "team1", 2);
    const bs = players(g, "team2", 6);
    for (const a of as) mustOk(g.rate(a, "e2", "plate", 1, t(2026, 12, 5)));
    for (const b of bs.slice(0, 5)) mustOk(g.rate(b, "e3", "plate", 1, t(2026, 12, 6)));
    const g2 = ownedArea();
    players(g2, "team1", 2).forEach((a) => mustOk(g2.rate(a, "e2", "plate", 1, t(2026, 12, 5))));
    players(g2, "team2", 6).forEach((b) => mustOk(g2.rate(b, "e3", "plate", 1, t(2026, 12, 6))));
    g.advanceTo(t(2027, 1, 1, 0));
    g2.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1", "5 is short of 3 x 2");
    assert.equal(g2.areas.get("a1")!.owner, "team2", "6 meets 3 x 2");
  });

  test("an owner with 0 new ratings loses to 1 (D6)", () => {
    const g = ownedArea();
    g.addPlayer("b", "team2");
    mustOk(g.rate("b", "e2", "plate", 1, t(2026, 12, 5)));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team2");
  });

  test("monthly totals reset: last month's ratings don't count", () => {
    const g = ownedArea();
    // team1 had 1 rating in November; in December it has 0, so 1 rating takes it.
    g.addPlayer("b", "team2");
    mustOk(g.rate("b", "e2", "plate", 1, t(2026, 12, 31, 23)));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team2");
    assert.equal(g.allTimeRatings.get("team1"), 1);
  });
});
