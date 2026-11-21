// Rules simulator: plays six months of one area under different player
// densities and reports how ownership behaves. Run: npm run simulate
//
// Player behaviour here is invented for testing the rules, not a forecast.

import { Game, type GameConfig, type TeamId } from "../src/engine.ts";
import { HOUR_MS, localMidnight, monthKey } from "../src/time.ts";

const TZ = "America/New_York";

function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export interface Scenario {
  name: string;
  establishments: number;
  /** Active players per team (team1, team2, team3). */
  teamSizes: [number, number, number];
  /** Chance per player per day of rating a new place. */
  rateChance: number;
  /** Chance per player per day of checking in somewhere. */
  checkInChance: number;
  /** Chance a team member votes yes on their team's Counterplate. */
  voteChance: number;
  months: number;
  seed: number;
  config?: Partial<GameConfig>;
}

export interface Summary {
  name: string;
  monthsOwned: Record<string, number>;
  monthEndTakeovers: number;
  earlyTurnovers: number;
  ownerless: number;
  establishmentSteals: number;
  counterplates: Record<string, number>;
  ratings: number;
  checkIns: number;
}

export function simulate(s: Scenario): Summary {
  const rand = rng(s.seed);
  const start = localMidnight(2026, 11, 1, TZ);
  const g = new Game(start, s.config);
  const ests = Array.from({ length: s.establishments }, (_, i) => `e${i}`);
  for (const e of ests) g.addEstablishment(e, "area");
  const teams: TeamId[] = g.config.teams;
  const roster: { id: string; team: TeamId }[] = [];
  teams.forEach((team, ti) => {
    for (let i = 0; i < s.teamSizes[ti]; i++) {
      const id = `${team}_${i}`;
      g.addPlayer(id, team);
      roster.push({ id, team });
    }
  });

  const monthsOwned: Record<string, number> = { team1: 0, team2: 0, team3: 0, nobody: 0 };
  const pick = <T>(xs: T[]) => xs[Math.floor(rand() * xs.length)];
  let day = start;
  const end = localMidnight(2026 + Math.floor((10 + s.months) / 12), ((10 + s.months) % 12) + 1, 1, TZ);
  let lastMonth = monthKey(day, TZ);

  while (day < end) {
    const actions: { at: number; run: () => void }[] = [];
    for (const p of roster) {
      const at = () => day + Math.floor(rand() * 14 + 8) * HOUR_MS + Math.floor(rand() * 60) * 60_000;
      if (rand() < s.rateChance) {
        const unrated = ests.filter((e) => !g.hasRated(p.id, e));
        if (unrated.length) {
          const e = pick(unrated);
          actions.push({ at: at(), run: () => void g.rate(p.id, e, rand() < 0.6 ? "plate" : "break", (1 + Math.floor(rand() * 3)) as 1 | 2 | 3, actionTime) });
        }
      }
      if (rand() < s.checkInChance) {
        // Players check in where they're allowed: places they rated, or anywhere in an area their team owns.
        const ownsArea = g.areas.get("area")!.owner === p.team;
        const allowed = ownsArea ? ests : ests.filter((e) => g.hasRated(p.id, e));
        if (!allowed.length) continue;
        const e = pick(allowed);
        actions.push({ at: at(), run: () => void g.checkIn(p.id, e, actionTime) });
      }
      for (const cp of g.counterplates) {
        if (cp.status === "voting" && cp.team === p.team && cp.eligibleVoters.includes(p.id) && rand() < s.voteChance) {
          actions.push({ at: at(), run: () => void g.vote(p.id, cp.id, actionTime) });
        }
      }
    }
    actions.sort((a, b) => a.at - b.at);
    let actionTime = day;
    for (const a of actions) {
      actionTime = Math.max(a.at, actionTime);
      a.run();
    }
    const next = day + 26 * HOUR_MS; // land safely in the next local day across DST
    day = localMidnight(...localYmd(next), TZ);
    g.advanceTo(Math.max(day, actionTime));
    const m = monthKey(day, TZ);
    if (m !== lastMonth) {
      monthsOwned[g.areas.get("area")!.owner ?? "nobody"] += 1;
      lastMonth = m;
    }
  }

  const count = (type: string, cause?: string) =>
    g.events.filter((e) => e.type === type && (cause === undefined || ("cause" in e && e.cause === cause))).length;
  const counterplates: Record<string, number> = {};
  for (const cp of g.counterplates) counterplates[cp.status] = (counterplates[cp.status] ?? 0) + 1;
  return {
    name: s.name,
    monthsOwned,
    monthEndTakeovers: count("area_taken", "month_end"),
    earlyTurnovers: count("area_taken", "early_turnover"),
    ownerless: count("area_ownerless"),
    establishmentSteals: count("establishment_stolen"),
    counterplates,
    ratings: g.ratings.length,
    checkIns: g.checkIns.length,
  };
}

function localYmd(ms: number): [number, number, number] {
  const f = new Intl.DateTimeFormat("en-US", { timeZone: TZ, year: "numeric", month: "numeric", day: "numeric" });
  const p: Record<string, string> = {};
  for (const x of f.formatToParts(new Date(ms))) p[x.type] = x.value;
  return [Number(p.year), Number(p.month), Number(p.day)];
}

export const SCENARIOS: Scenario[] = [
  { name: "Sparse: 1 player each on two teams", establishments: 8, teamSizes: [1, 1, 0], rateChance: 0.05, checkInChance: 0.15, voteChance: 0.8, months: 6, seed: 1 },
  { name: "Lopsided: 6 vs 1 vs 1", establishments: 12, teamSizes: [6, 1, 1], rateChance: 0.05, checkInChance: 0.15, voteChance: 0.6, months: 6, seed: 2 },
  { name: "Even: 5 per team", establishments: 20, teamSizes: [5, 5, 5], rateChance: 0.05, checkInChance: 0.15, voteChance: 0.6, months: 6, seed: 3 },
  { name: "Busy: 20 per team", establishments: 25, teamSizes: [20, 20, 20], rateChance: 0.05, checkInChance: 0.2, voteChance: 0.5, months: 6, seed: 4 },
];

/** Runs each scenario over many seeds and adds the results up. */
export function simulateMany(s: Scenario, runs: number): Summary {
  const total: Summary = { name: s.name, monthsOwned: { team1: 0, team2: 0, team3: 0, nobody: 0 }, monthEndTakeovers: 0, earlyTurnovers: 0, ownerless: 0, establishmentSteals: 0, counterplates: {}, ratings: 0, checkIns: 0 };
  for (let i = 0; i < runs; i++) {
    const r = simulate({ ...s, seed: s.seed * 1000 + i });
    for (const k of Object.keys(total.monthsOwned)) total.monthsOwned[k] += r.monthsOwned[k];
    total.monthEndTakeovers += r.monthEndTakeovers;
    total.earlyTurnovers += r.earlyTurnovers;
    total.ownerless += r.ownerless;
    total.establishmentSteals += r.establishmentSteals;
    total.ratings += r.ratings;
    total.checkIns += r.checkIns;
    for (const [k, v] of Object.entries(r.counterplates)) total.counterplates[k] = (total.counterplates[k] ?? 0) + v;
  }
  return total;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const runs = Number(process.argv[2] ?? 50);
  console.log(`Totals over ${runs} six-month runs per scenario.\n`);
  const rows = SCENARIOS.map((s) => simulateMany(s, runs));
  console.log("| Scenario | Area-months owned (t1/t2/t3/none) | Month-end takeovers | Early turnovers | Went ownerless | Establishment steals | Counterplates | Ratings | Check-ins |");
  console.log("| --- | --- | --- | --- | --- | --- | --- | --- | --- |");
  for (const r of rows) {
    const mo = r.monthsOwned;
    const cps = Object.entries(r.counterplates).map(([k, v]) => `${k} ${v}`).join(", ") || "none";
    console.log(`| ${r.name} | ${mo.team1}/${mo.team2}/${mo.team3}/${mo.nobody} | ${r.monthEndTakeovers} | ${r.earlyTurnovers} | ${r.ownerless} | ${r.establishmentSteals} | ${cps} | ${r.ratings} | ${r.checkIns} |`);
  }
}
