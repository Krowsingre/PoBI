// Plate or Break It game rules engine.
//
// Pure, deterministic and clock-injected: every action carries its own time
// (`at`, epoch ms) and timers (Counterplate votes and battles, month-end
// evaluations) fire in time order before the action runs. Nothing here trusts
// the phone: the server feeds verified events in and stores the results.
//
// Rule references (D1-D10, Q*) point to the decisions doc:
// https://claude.ai/artifact/YS91THrAyzvEsFYKt8GgW1

import { DAY_MS, HOUR_MS, dayKey, monthKey, startOfNextMonth, weekKey } from "./time.ts";

export type TeamId = string;
export type Verdict = "plate" | "break";

export interface GameConfig {
  /** D1: three teams at launch. Names are placeholders until embre picks identities. */
  teams: TeamId[];
  /** D9: New Jersey launch, one zone. */
  timeZone: string;
  /** D2: standard takeover multiplier for areas (ratings) and establishments (check-ins). */
  takeoverMultiplier: number;
  /** Q3/QA: the establishment owner's defense is its check-ins over this many days. */
  ownerDefenseWindowDays: number;
  /**
   * How the challenger's check-ins are counted when stealing an establishment.
   * "month": count starts from 0 each month (embre: "count to start from 0 for the current month").
   * "rolling": same rolling window as the owner. Default "month"; flagged for confirmation.
   */
  challengerWindow: "month" | "rolling";
  /** Early turnover: holder keeps the area at month end with this share of the usual bar (embre: 1/2). */
  earlyTurnoverShare: number;
  /** D5: Counterplate ladder start and step. Multiplier = min(takeoverMultiplier, start + step * transfers). */
  counterplateStart: number;
  counterplateStep: number;
  /** Counterplate vote: 24 h, 30% of eligible local members (confirmed rules). */
  voteHours: number;
  voteShare: number;
  /** Counterplate battle length (confirmed: three days). */
  battleHours: number;
  /** 31.14 recommendation (not approved): eligible voters were active in the area in this many days. */
  voterActivityDays: number;
}

export const DEFAULT_CONFIG: GameConfig = {
  teams: ["team1", "team2", "team3"],
  timeZone: "America/New_York",
  takeoverMultiplier: 3,
  ownerDefenseWindowDays: 30,
  challengerWindow: "month",
  earlyTurnoverShare: 0.5,
  counterplateStart: 1.5,
  counterplateStep: 0.5,
  voteHours: 24,
  voteShare: 0.3,
  battleHours: 72,
  voterActivityDays: 30,
};

export interface Player {
  id: string;
  team: TeamId;
}

export interface Establishment {
  id: string;
  areaId: string;
  /** Owned through check-ins (D7). null = unclaimed. */
  owner: TeamId | null;
}

export interface EarlyTurnover {
  /** The legitimate owner the area was taken from mid-month. */
  previousOwner: TeamId;
  at: number;
}

export interface Area {
  id: string;
  /** Owned through new ratings at month end, or provisionally by early turnover (D7). */
  owner: TeamId | null;
  earlyTurnover: EarlyTurnover | null;
}

export interface Rating {
  playerId: string;
  team: TeamId;
  establishmentId: string;
  areaId: string;
  verdict: Verdict;
  stars: 1 | 2 | 3;
  at: number;
  month: string;
}

export interface CheckIn {
  playerId: string;
  team: TeamId;
  establishmentId: string;
  areaId: string;
  /** "rated": daily check-in at a place the player rated. "weekly": owner-area perk at an unrated place (D10). */
  kind: "rated" | "weekly";
  at: number;
  day: string;
  week: string;
  month: string;
}

export type CounterplateStatus =
  | "voting"
  | "battle"
  | "won" // reduced bar active for `evaluateMonth`
  | "lost_battle"
  | "failed_vote"
  | "no_eligible_voters"
  | "reclaimed"
  | "exhausted" // ladder reached the standard multiplier
  | "expired"; // evaluation passed without reclaiming

export interface Counterplate {
  id: string;
  areaId: string;
  /** The team that lost the area and may contest. */
  team: TeamId;
  /** The team that took it. */
  against: TeamId;
  lostAt: number;
  voteClosesAt: number;
  eligibleVoters: string[];
  votesNeeded: number;
  votes: string[];
  battleEndsAt: number | null;
  battleScore: Record<TeamId, number> | null;
  /** Ownership transfers of the area after the original loss (D5 ladder). */
  transfers: number;
  /** Month whose end-of-month evaluation uses the reduced bar. */
  evaluateMonth: string | null;
  status: CounterplateStatus;
}

export type GameEvent =
  | { type: "establishment_claimed"; at: number; establishmentId: string; team: TeamId }
  | { type: "establishment_stolen"; at: number; establishmentId: string; from: TeamId; to: TeamId; challengerCount: number; ownerCount: number }
  | { type: "area_claimed"; at: number; areaId: string; team: TeamId; ratings: number }
  | { type: "area_taken"; at: number; areaId: string; from: TeamId; to: TeamId; cause: "month_end" | "early_turnover" | "early_turnover_reversed" }
  | { type: "area_kept"; at: number; areaId: string; team: TeamId }
  | { type: "area_ownerless"; at: number; areaId: string; from: TeamId; reason: string }
  | { type: "counterplate_opened"; at: number; counterplateId: string; areaId: string; team: TeamId; against: TeamId; votesNeeded: number }
  | { type: "counterplate_status"; at: number; counterplateId: string; status: CounterplateStatus }
  | { type: "month_evaluated"; at: number; month: string };

export type Result = { ok: true } | { ok: false; reason: string };

const ok: Result = { ok: true };
const fail = (reason: string): Result => ({ ok: false, reason });

/** Threshold rule shared by areas and establishments: multiplier x owner's count, rounded up; 0 needs 1 (D6, K2). */
export function bar(multiplier: number, ownerCount: number): number {
  if (ownerCount <= 0) return 1;
  return Math.max(1, Math.ceil(multiplier * ownerCount - 1e-9));
}

export class Game {
  readonly config: GameConfig;
  readonly players = new Map<string, Player>();
  readonly establishments = new Map<string, Establishment>();
  readonly areas = new Map<string, Area>();
  readonly ratings: Rating[] = [];
  readonly checkIns: CheckIn[] = [];
  readonly counterplates: Counterplate[] = [];
  readonly events: GameEvent[] = [];
  /** All-time rating totals per team (stored, no game effect yet: decided 2026-11-21). */
  readonly allTimeRatings = new Map<TeamId, number>();

  private now: number;
  private currentMonth: string;
  private nextCounterplateId = 1;

  constructor(startAt: number, config: Partial<GameConfig> = {}) {
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.now = startAt;
    this.currentMonth = monthKey(startAt, this.config.timeZone);
  }

  // ---------------------------------------------------------------- setup

  addPlayer(id: string, team: TeamId): void {
    if (!this.config.teams.includes(team)) throw new Error(`unknown team ${team}`);
    this.players.set(id, { id, team });
  }

  addEstablishment(id: string, areaId: string): void {
    this.establishments.set(id, { id, areaId, owner: null });
    if (!this.areas.has(areaId)) this.areas.set(areaId, { id: areaId, owner: null, earlyTurnover: null });
  }

  // ---------------------------------------------------------------- actions

  /** An original, already-verified rating (D4 checks happen before this is called). */
  rate(playerId: string, establishmentId: string, verdict: Verdict, stars: 1 | 2 | 3, at: number): Result {
    const pre = this.begin(at);
    if (!pre.ok) return pre;
    const player = this.players.get(playerId);
    const est = this.establishments.get(establishmentId);
    if (!player) return fail("unknown_player");
    if (!est) return fail("unknown_establishment");
    if (![1, 2, 3].includes(stars)) return fail("bad_stars");
    if (verdict !== "plate" && verdict !== "break") return fail("bad_verdict");
    if (this.hasRated(playerId, establishmentId)) return fail("already_rated");
    this.ratings.push({
      playerId,
      team: player.team,
      establishmentId,
      areaId: est.areaId,
      verdict,
      stars,
      at,
      month: monthKey(at, this.config.timeZone),
    });
    this.allTimeRatings.set(player.team, (this.allTimeRatings.get(player.team) ?? 0) + 1);
    return ok;
  }

  /** A presence-verified check-in (31.8 validation happens before this is called). */
  checkIn(playerId: string, establishmentId: string, at: number): Result {
    const pre = this.begin(at);
    if (!pre.ok) return pre;
    const player = this.players.get(playerId);
    const est = this.establishments.get(establishmentId);
    if (!player) return fail("unknown_player");
    if (!est) return fail("unknown_establishment");
    const tz = this.config.timeZone;
    const area = this.areas.get(est.areaId)!;
    const rated = this.hasRated(playerId, establishmentId);
    const day = dayKey(at, tz);
    const week = weekKey(at, tz);
    let kind: CheckIn["kind"];
    if (rated) {
      if (this.checkIns.some((c) => c.playerId === playerId && c.establishmentId === establishmentId && c.day === day)) {
        return fail("already_checked_in_today");
      }
      kind = "rated";
    } else {
      // D10: unrated places only in an area your team owns, once per Sunday-start week.
      if (area.owner !== player.team) return fail("not_rated_and_area_not_owned");
      if (this.checkIns.some((c) => c.playerId === playerId && c.establishmentId === establishmentId && c.kind === "weekly" && c.week === week)) {
        return fail("weekly_check_in_used");
      }
      kind = "weekly";
    }
    this.checkIns.push({
      playerId,
      team: player.team,
      establishmentId,
      areaId: est.areaId,
      kind,
      at,
      day,
      week,
      month: monthKey(at, tz),
    });
    this.updateEstablishmentOwner(est, player.team, at);
    return ok;
  }

  vote(playerId: string, counterplateId: string, at: number): Result {
    const pre = this.begin(at);
    if (!pre.ok) return pre;
    const cp = this.counterplates.find((c) => c.id === counterplateId);
    if (!cp) return fail("unknown_counterplate");
    if (cp.status !== "voting") return fail("voting_closed");
    if (!cp.eligibleVoters.includes(playerId)) return fail("not_eligible");
    if (cp.votes.includes(playerId)) return fail("already_voted");
    cp.votes.push(playerId);
    return ok;
  }

  /** Run every timer due at or before `at` (vote closes, battle ends, month ends). */
  advanceTo(at: number): void {
    if (at < this.now) throw new Error("time went backwards");
    for (;;) {
      const next = this.nextTimer();
      if (!next || next.time > at) break;
      this.now = next.time;
      next.run();
    }
    this.now = at;
  }

  // ---------------------------------------------------------------- queries

  hasRated(playerId: string, establishmentId: string): boolean {
    return this.ratings.some((r) => r.playerId === playerId && r.establishmentId === establishmentId);
  }

  areaEstablishments(areaId: string): Establishment[] {
    return [...this.establishments.values()].filter((e) => e.areaId === areaId);
  }

  /** Team's check-ins at an establishment in (at - days, at]. */
  checkInsInWindow(team: TeamId, establishmentId: string, at: number, days: number): number {
    const from = at - days * DAY_MS;
    return this.checkIns.filter((c) => c.team === team && c.establishmentId === establishmentId && c.at > from && c.at <= at).length;
  }

  checkInsInMonth(team: TeamId, establishmentId: string, month: string): number {
    return this.checkIns.filter((c) => c.team === team && c.establishmentId === establishmentId && c.month === month).length;
  }

  newRatingsInArea(areaId: string, month: string): Map<TeamId, Rating[]> {
    const byTeam = new Map<TeamId, Rating[]>();
    for (const t of this.config.teams) byTeam.set(t, []);
    for (const r of this.ratings) if (r.areaId === areaId && r.month === month) byTeam.get(r.team)!.push(r);
    return byTeam;
  }

  /** Current multiplier a team needs to take an area, including any Counterplate advantage for `month`. */
  areaMultiplierFor(team: TeamId, areaId: string, month: string): number {
    const cp = this.counterplates.find((c) => c.areaId === areaId && c.team === team && c.status === "won" && c.evaluateMonth === month);
    return cp ? this.ladder(cp) : this.config.takeoverMultiplier;
  }

  ladder(cp: Counterplate): number {
    const { counterplateStart, counterplateStep, takeoverMultiplier } = this.config;
    return Math.min(takeoverMultiplier, counterplateStart + counterplateStep * cp.transfers);
  }

  // ---------------------------------------------------------------- internals

  private begin(at: number): Result {
    if (at < this.now) return fail("out_of_order");
    this.advanceTo(at);
    return ok;
  }

  private log(e: GameEvent): void {
    this.events.push(e);
  }

  private nextTimer(): { time: number; run: () => void } | null {
    const timers: { time: number; order: number; run: () => void }[] = [];
    for (const cp of this.counterplates) {
      if (cp.status === "voting") timers.push({ time: cp.voteClosesAt, order: 0, run: () => this.closeVote(cp) });
      if (cp.status === "battle" && cp.battleEndsAt !== null) timers.push({ time: cp.battleEndsAt, order: 0, run: () => this.endBattle(cp) });
    }
    const month = this.currentMonth;
    timers.push({ time: startOfNextMonth(month, this.config.timeZone), order: 1, run: () => this.evaluateMonth(month) });
    timers.sort((a, b) => a.time - b.time || a.order - b.order);
    return timers[0] ?? null;
  }

  // Establishments: check-ins at any time (D7, D2, D6, QA).
  private updateEstablishmentOwner(est: Establishment, team: TeamId, at: number): void {
    if (est.owner === team) return;
    if (est.owner === null) {
      est.owner = team;
      this.log({ type: "establishment_claimed", at, establishmentId: est.id, team });
    } else {
      const ownerCount = this.checkInsInWindow(est.owner, est.id, at, this.config.ownerDefenseWindowDays);
      const challengerCount =
        this.config.challengerWindow === "month"
          ? this.checkInsInMonth(team, est.id, monthKey(at, this.config.timeZone))
          : this.checkInsInWindow(team, est.id, at, this.config.ownerDefenseWindowDays);
      if (challengerCount < bar(this.config.takeoverMultiplier, ownerCount)) return;
      const from = est.owner;
      est.owner = team;
      this.log({ type: "establishment_stolen", at, establishmentId: est.id, from, to: team, challengerCount, ownerCount });
    }
    this.checkEarlyTurnover(est.areaId, team, at);
  }

  // Taking every claimed establishment in an owned area hands over the area for now (D7).
  private checkEarlyTurnover(areaId: string, team: TeamId, at: number): void {
    const area = this.areas.get(areaId)!;
    if (area.owner === null || area.owner === team) return;
    const claimed = this.areaEstablishments(areaId).filter((e) => e.owner !== null);
    if (claimed.length === 0 || !claimed.every((e) => e.owner === team)) return;
    const legit = area.earlyTurnover ? area.earlyTurnover.previousOwner : area.owner;
    if (team === legit) {
      // The legitimate owner took everything back before month end.
      const from = area.owner;
      area.earlyTurnover = null;
      this.transferArea(area, team, at, "early_turnover_reversed", from, null);
    } else {
      const from = area.owner;
      const firstLoss = area.earlyTurnover === null;
      area.earlyTurnover = { previousOwner: legit, at };
      // Only the legitimate owner gets Counterplate; a provisional holder losing it does not.
      this.transferArea(area, team, at, "early_turnover", from, firstLoss ? from : null);
    }
  }

  /** `counterplateFor`: the legitimate owner who just lost the area and may contest, or null. */
  private transferArea(
    area: Area,
    to: TeamId,
    at: number,
    cause: "month_end" | "early_turnover" | "early_turnover_reversed",
    from: TeamId,
    counterplateFor: TeamId | null,
  ): void {
    area.owner = to;
    this.log({ type: "area_taken", at, areaId: area.id, from, to, cause });
    // D5 ladder: every later transfer raises open Counterplate bars for this area.
    for (const cp of this.counterplates) {
      if (cp.areaId !== area.id) continue;
      if (!["voting", "battle", "won"].includes(cp.status)) continue;
      if (cp.team === to) {
        this.setStatus(cp, "reclaimed", at);
        continue;
      }
      cp.transfers += 1;
      if (cp.status === "won" && this.ladder(cp) >= this.config.takeoverMultiplier) this.setStatus(cp, "exhausted", at);
    }
    if (counterplateFor !== null) this.openCounterplate(area, counterplateFor, to, at);
  }

  private openCounterplate(area: Area, team: TeamId, against: TeamId, at: number): void {
    const already = this.counterplates.some(
      (c) => c.areaId === area.id && c.team === team && ["voting", "battle", "won"].includes(c.status),
    );
    if (already) return;
    const since = at - this.config.voterActivityDays * DAY_MS;
    const active = new Set<string>();
    for (const r of this.ratings) if (r.areaId === area.id && r.team === team && r.at > since && r.at <= at) active.add(r.playerId);
    for (const c of this.checkIns) if (c.areaId === area.id && c.team === team && c.at > since && c.at <= at) active.add(c.playerId);
    const eligibleVoters = [...active].sort();
    const cp: Counterplate = {
      id: `cp${this.nextCounterplateId++}`,
      areaId: area.id,
      team,
      against,
      lostAt: at,
      voteClosesAt: at + this.config.voteHours * HOUR_MS,
      eligibleVoters,
      votesNeeded: Math.ceil(this.config.voteShare * eligibleVoters.length - 1e-9),
      votes: [],
      battleEndsAt: null,
      battleScore: null,
      transfers: 0,
      evaluateMonth: null,
      status: eligibleVoters.length === 0 ? "no_eligible_voters" : "voting",
    };
    this.counterplates.push(cp);
    this.log({ type: "counterplate_opened", at, counterplateId: cp.id, areaId: area.id, team, against, votesNeeded: cp.votesNeeded });
    if (cp.status !== "voting") this.log({ type: "counterplate_status", at, counterplateId: cp.id, status: cp.status });
  }

  private setStatus(cp: Counterplate, status: CounterplateStatus, at: number): void {
    cp.status = status;
    this.log({ type: "counterplate_status", at, counterplateId: cp.id, status });
  }

  private closeVote(cp: Counterplate): void {
    if (cp.votes.length >= cp.votesNeeded && cp.votesNeeded > 0) {
      cp.battleEndsAt = cp.voteClosesAt + this.config.battleHours * HOUR_MS;
      this.setStatus(cp, "battle", cp.voteClosesAt);
    } else {
      this.setStatus(cp, "failed_vote", cp.voteClosesAt);
    }
  }

  // 31.15 recommendation (not approved): check-ins at every establishment in the area, only the two teams count, tie = no advantage.
  private endBattle(cp: Counterplate): void {
    const start = cp.voteClosesAt;
    const end = cp.battleEndsAt!;
    const score: Record<TeamId, number> = { [cp.team]: 0, [cp.against]: 0 };
    for (const c of this.checkIns) {
      if (c.areaId !== cp.areaId || c.at < start || c.at >= end) continue;
      if (c.team === cp.team || c.team === cp.against) score[c.team] += 1;
    }
    cp.battleScore = score;
    if (score[cp.team] > score[cp.against]) {
      // Reduced bar applies at the next month-end evaluation after the battle (proposal 16).
      cp.evaluateMonth = monthKey(end, this.config.timeZone);
      this.setStatus(cp, this.ladder(cp) >= this.config.takeoverMultiplier ? "exhausted" : "won", end);
    } else {
      this.setStatus(cp, "lost_battle", end);
    }
  }

  // Areas: new ratings, evaluated at local month end (D7, D2, D6, Q-answers).
  private evaluateMonth(month: string): void {
    const at = this.now;
    for (const area of this.areas.values()) this.evaluateArea(area, month, at);
    for (const cp of this.counterplates) {
      if (cp.status === "won" && cp.evaluateMonth === month) this.setStatus(cp, "expired", at);
    }
    this.log({ type: "month_evaluated", at, month });
    this.currentMonth = monthKey(at, this.config.timeZone);
  }

  private evaluateArea(area: Area, month: string, at: number): void {
    const byTeam = this.newRatingsInArea(area.id, month);
    const count = (t: TeamId) => byTeam.get(t)!.length;

    if (area.owner === null) {
      // Unowned: the team with the most new ratings claims it. A tie leaves it unowned (not yet decided; flagged).
      const ranked = this.config.teams.map((t) => ({ t, n: count(t) })).sort((a, b) => b.n - a.n);
      if (ranked[0].n > 0 && ranked[0].n > (ranked[1]?.n ?? 0)) {
        area.owner = ranked[0].t;
        this.log({ type: "area_claimed", at, areaId: area.id, team: ranked[0].t, ratings: ranked[0].n });
      }
      return;
    }

    const owner = area.owner;
    const early = area.earlyTurnover;
    area.earlyTurnover = null;
    const ownerCount = count(owner);

    // Challengers need multiplier x the current holder's new ratings (Counterplate lowers it).
    const qualified: { t: TeamId; n: number; reachedAt: number }[] = [];
    for (const t of this.config.teams) {
      if (t === owner) continue;
      const need = bar(this.areaMultiplierFor(t, area.id, month), ownerCount);
      const list = byTeam.get(t)!;
      if (list.length >= need) qualified.push({ t, n: list.length, reachedAt: list.map((r) => r.at).sort((a, b) => a - b)[need - 1] });
    }

    if (qualified.length > 0) {
      // 31.13 recommendation (not approved): most ratings wins, tie goes to whoever reached its bar first.
      qualified.sort((a, b) => b.n - a.n || a.reachedAt - b.reachedAt);
      this.transferArea(area, qualified[0].t, at, "month_end", owner, early ? null : owner);
      return;
    }

    if (early) {
      // Early-turnover holder keeps it only with 1/2 of the usual bar against the previous owner.
      const need = bar(this.config.takeoverMultiplier * this.config.earlyTurnoverShare, count(early.previousOwner));
      if (ownerCount < need) {
        // Neither side reached its bar: the area becomes ownerless (embre, 2026-11-21).
        area.owner = null;
        this.log({ type: "area_ownerless", at, areaId: area.id, from: owner, reason: "early_turnover_bar_missed" });
        for (const cp of this.counterplates) {
          if (cp.areaId === area.id && ["voting", "battle", "won"].includes(cp.status)) this.setStatus(cp, "expired", at);
        }
        return;
      }
    }
    this.log({ type: "area_kept", at, areaId: area.id, team: owner });
  }
}
