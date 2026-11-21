import { Game, type GameConfig, type TeamId } from "../src/engine.ts";
import { HOUR_MS, localMidnight } from "../src/time.ts";

export const TZ = "America/New_York";

/** Local New Jersey time as epoch ms. */
export function t(year: number, month: number, day: number, hour = 12, minute = 0): number {
  return localMidnight(year, month, day, TZ) + hour * HOUR_MS + minute * 60_000;
}

/** A game starting 2026-11-01 with three teams. */
export function newGame(config: Partial<GameConfig> = {}): Game {
  return new Game(t(2026, 11, 1, 0), config);
}

/** Adds `n` players to a team, named `${prefix}${i}`. */
export function players(g: Game, team: TeamId, n: number, prefix = team + "_"): string[] {
  const ids: string[] = [];
  for (let i = 0; i < n; i++) {
    const id = `${prefix}${i}`;
    g.addPlayer(id, team);
    ids.push(id);
  }
  return ids;
}

export function mustOk(r: { ok: boolean; reason?: string }): void {
  if (!r.ok) throw new Error(`expected ok, got ${r.reason}`);
}
