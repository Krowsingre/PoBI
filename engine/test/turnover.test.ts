import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mustOk, newGame, players, t } from "./helpers.ts";

/**
 * team1 owns area a1 from Dec 1 (founder rated and checked in at e1 on Nov 10).
 * On Dec 3 three team2 players rate and check in at e1, stealing the only
 * claimed establishment, which hands team2 the area early.
 */
function earlyTurnover() {
  const g = newGame();
  for (let i = 1; i <= 5; i++) g.addEstablishment(`e${i}`, "a1");
  g.addPlayer("founder", "team1");
  mustOk(g.rate("founder", "e1", "plate", 3, t(2026, 11, 10)));
  mustOk(g.checkIn("founder", "e1", t(2026, 11, 10)));
  g.advanceTo(t(2026, 12, 1, 0));
  const bs = players(g, "team2", 3);
  bs.forEach((b, i) => {
    mustOk(g.rate(b, "e1", "plate", 2, t(2026, 12, 3, 10 + i)));
    mustOk(g.checkIn(b, "e1", t(2026, 12, 3, 10 + i)));
  });
  return { g, bs };
}

describe("early turnover", () => {
  test("stealing every claimed establishment hands over the area and opens Counterplate", () => {
    const { g } = earlyTurnover();
    const area = g.areas.get("a1")!;
    assert.equal(area.owner, "team2");
    assert.equal(area.earlyTurnover?.previousOwner, "team1");
    const cp = g.counterplates[0];
    assert.equal(cp.team, "team1");
    assert.equal(cp.against, "team2");
    assert.deepEqual(cp.eligibleVoters, ["founder"]);
    assert.equal(cp.votesNeeded, 1);
  });

  test("holder keeps the area with 1/2 of the usual bar (1x the previous owner)", () => {
    const { g } = earlyTurnover();
    // team2 has 3 December ratings, team1 has 0: holder needs 1.
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team2");
    assert.equal(g.areas.get("a1")!.earlyTurnover, null);
  });

  test("if neither side reaches its bar the area becomes ownerless", () => {
    const { g } = earlyTurnover();
    // team1 rates 4: holder needs 1 x 4 = 4 (has 3); team1 needs 2 x 3 = 6 (has 4).
    players(g, "team1", 4).forEach((p) => mustOk(g.rate(p, "e2", "plate", 1, t(2026, 12, 10))));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, null);
    assert.ok(g.events.some((e) => e.type === "area_ownerless"));
  });

  test("the previous owner reclaims at month end with 2x the holder's ratings", () => {
    const { g } = earlyTurnover();
    players(g, "team1", 6).forEach((p) => mustOk(g.rate(p, "e2", "plate", 1, t(2026, 12, 10))));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1");
  });

  test("winning every establishment back mid-month reverses the turnover", () => {
    const { g } = earlyTurnover();
    // team2 has 3 check-ins at e1 in 30 days, so team1 needs 9 this month.
    players(g, "team1", 9).forEach((p) => {
      mustOk(g.rate(p, "e1", "plate", 1, t(2026, 12, 4, 10)));
      mustOk(g.checkIn(p, "e1", t(2026, 12, 4, 10)));
    });
    const area = g.areas.get("a1")!;
    assert.equal(area.owner, "team1");
    assert.equal(area.earlyTurnover, null);
    assert.equal(g.counterplates[0].status, "reclaimed");
  });
});

describe("Counterplate", () => {
  /** founder votes, then wins the 3-day battle 3 check-ins to 1. */
  function wonCounterplate() {
    const { g, bs } = earlyTurnover();
    const cp = g.counterplates[0];
    mustOk(g.vote("founder", cp.id, t(2026, 12, 3, 13)));
    g.advanceTo(t(2026, 12, 4, 12));
    assert.equal(cp.status, "battle");
    mustOk(g.checkIn("founder", "e1", t(2026, 12, 4, 13)));
    mustOk(g.checkIn("founder", "e1", t(2026, 12, 5, 13)));
    mustOk(g.checkIn(bs[0], "e1", t(2026, 12, 5, 14)));
    mustOk(g.checkIn("founder", "e1", t(2026, 12, 6, 13)));
    g.advanceTo(t(2026, 12, 7, 12));
    assert.equal(cp.status, "won");
    assert.deepEqual(cp.battleScore, { team1: 3, team2: 1 });
    assert.equal(cp.evaluateMonth, "2026-12");
    return { g, cp };
  }

  test("a vote short of 30% fails after 24 hours", () => {
    const { g } = earlyTurnover();
    g.advanceTo(t(2026, 12, 4, 12));
    assert.equal(g.counterplates[0].status, "failed_vote");
  });

  test("no recently active members means no vote", () => {
    const g = newGame();
    g.addEstablishment("e1", "a1");
    g.addPlayer("founder", "team1");
    g.addPlayer("b", "team2");
    mustOk(g.rate("founder", "e1", "plate", 3, t(2026, 11, 1, 9)));
    mustOk(g.checkIn("founder", "e1", t(2026, 11, 1, 9)));
    g.advanceTo(t(2026, 12, 1, 0));
    mustOk(g.rate("b", "e1", "plate", 1, t(2026, 12, 5)));
    mustOk(g.checkIn("b", "e1", t(2026, 12, 5)));
    assert.equal(g.areas.get("a1")!.owner, "team2");
    assert.equal(g.counterplates[0].status, "no_eligible_voters");
  });

  test("a won Counterplate lowers the month-end bar to 1x", () => {
    const { g, cp } = wonCounterplate();
    // team2 has 3 December ratings: matching them is enough (instead of 6).
    players(g, "team1", 3).forEach((p) => mustOk(g.rate(p, "e2", "plate", 1, t(2026, 12, 20))));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1");
    assert.equal(cp.status, "reclaimed");
  });

  test("one rating short of the reduced bar: the holder keeps it", () => {
    const { g, cp } = wonCounterplate();
    // team1 has 2: short of 1 x 3. Holder needs 1 x 2 and has 3.
    players(g, "team1", 2).forEach((p) => mustOk(g.rate(p, "e2", "plate", 1, t(2026, 12, 20))));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team2");
    assert.equal(cp.status, "expired");
  });

  test("a tie between holder and Counterplate winner goes to the Counterplate winner", () => {
    const { g, cp } = wonCounterplate();
    // Both have 3: team1 meets 1 x 3, and the holder also meets its own bar.
    players(g, "team1", 3).forEach((p) => mustOk(g.rate(p, "e2", "plate", 1, t(2026, 12, 20))));
    g.advanceTo(t(2027, 1, 1, 0));
    assert.equal(g.areas.get("a1")!.owner, "team1");
    assert.equal(cp.status, "reclaimed");
  });

  test("each later transfer raises the bar by 0.5x (ladder 1x -> 1.5x -> 2x)", () => {
    const { g } = wonCounterplate();
    assert.equal(g.areaMultiplierFor("team1", "a1", "2026-12"), 1);
    // team3 steals e1 from team2 (4 check-ins in 30 days, so 12 needed): area changes hands again.
    players(g, "team3", 12).forEach((p) => {
      mustOk(g.rate(p, "e1", "plate", 1, t(2026, 12, 8)));
      mustOk(g.checkIn(p, "e1", t(2026, 12, 8)));
    });
    const area = g.areas.get("a1")!;
    assert.equal(area.owner, "team3");
    assert.equal(area.earlyTurnover?.previousOwner, "team1");
    assert.equal(g.areaMultiplierFor("team1", "a1", "2026-12"), 1.5);
    assert.equal(g.areaMultiplierFor("team2", "a1", "2026-12"), 2, "no advantage for the provisional holder");
  });
});
