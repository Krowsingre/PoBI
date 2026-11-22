// Pure part of the game runner: turns database rows into ownership, using the rules engine.
import { Game } from "../../engine/src/engine.ts";

export interface PlayerRow { id: string; team: string | null }
export interface RatingRow {
  player_id: string; place_id: string; verdict: "plateIt" | "breakIt"; stars: number;
  counted_at: string;
}
export interface CheckInRow { player_id: string; place_id: string; checked_at: string }
export interface PlaceRow { id: string; area: string }

export interface Ownership {
  areas: Map<string, string>;
  places: Map<string, { team: string; area: string }>;
  /** Why some rows didn't count, by reason. */
  skipped: Record<string, number>;
}

type Event =
  | { kind: "rate"; at: number; row: RatingRow }
  | { kind: "checkIn"; at: number; row: CheckInRow };

export function replay(
  players: PlayerRow[], ratings: RatingRow[], checkIns: CheckInRow[], places: PlaceRow[], now: number,
): Ownership {
  const events: Event[] = [
    ...ratings.map((row): Event => ({ kind: "rate", at: Date.parse(row.counted_at), row })),
    ...checkIns.map((row): Event => ({ kind: "checkIn", at: Date.parse(row.checked_at), row })),
  ];
  // Ratings before check-ins at the same instant, so a check-in can follow its rating.
  events.sort((a, b) => a.at - b.at || (a.kind === "rate" ? -1 : 1));

  const skipped: Record<string, number> = {};
  const skip = (reason: string) => { skipped[reason] = (skipped[reason] ?? 0) + 1; };

  const start = events.length ? Math.min(events[0].at, now) : now;
  const game = new Game(start);
  for (const p of players) if (p.team) game.addPlayer(p.id, p.team);
  for (const place of places) game.addEstablishment(place.id, place.area);

  for (const e of events) {
    if (e.at > now) { skip("in_future"); continue; }
    const result = e.kind === "rate"
      ? game.rate(e.row.player_id, e.row.place_id, e.row.verdict === "plateIt" ? "plate" : "break",
                  e.row.stars as 1 | 2 | 3, e.at)
      : game.checkIn(e.row.player_id, e.row.place_id, e.at);
    if (!result.ok) skip(`${e.kind}:${result.reason}`);
  }
  game.advanceTo(now);

  const areas = new Map<string, string>();
  for (const area of game.areas.values()) if (area.owner) areas.set(area.id, area.owner);
  const owned = new Map<string, { team: string; area: string }>();
  for (const est of game.establishments.values()) {
    if (est.owner) owned.set(est.id, { team: est.owner, area: est.areaId });
  }
  return { areas, places: owned, skipped };
}
