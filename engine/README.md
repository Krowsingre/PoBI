# Game rules engine

Every rule from the decisions doc as plain, deterministic TypeScript. Each action carries its own time, and timers (Counterplate votes and battles, month-end evaluations) run in time order, so the server can replay events exactly.

```sh
npm test            # 28 rule tests
npm run simulate    # six months of play in sparse to busy areas (50 runs each)
```

Needs Node 22.18 or newer (runs TypeScript directly, no build step).

## What it covers

- **Ratings:** one original rating per player per place. All-time team totals are stored but don't affect play yet.
- **Check-ins (D10):** once a day where you've rated. Once a week (Sunday to Saturday, never reset by the month) at each unrated place in an area your team owns.
- **Establishments (D7):** first check-in claims. Stealing needs 3x the owner's check-ins over the last 30 days, counting the challenger's check-ins this month. An owner with 0 loses to 1.
- **Areas (D7):** an unowned area goes to the team with the most new ratings at month end. Taking an owned area needs 3x the owner's new ratings that month.
- **Early turnover:** stealing every claimed establishment in an owned area hands it over for now. The holder keeps it at month end with 1/2 of the usual bar (1.5x the previous owner's new ratings). If neither side reaches its bar, the area becomes ownerless.
- **Counterplate:** losing an area opens a 24-hour vote (30% of recently active local members), then a 72-hour check-in battle. Winning lowers the month-end bar to 1.5x, rising 0.5x per later transfer up to 3x (D5). Fractions round up.

## Working assumptions (not yet confirmed by embre)

These are the decisions doc's recommendations, or gaps found while coding. Each is a config value or one function.

- A tie for an unowned area leaves it unowned.
- Several qualifying challengers: most ratings wins; a tie goes to whoever reached its bar first (31.13).
- Eligible Counterplate voters: team members with a rating or check-in in the area in the last 30 days (31.14).
- Battle score: check-ins at every establishment in the area; only the two teams count; a tie means no reduced bar (31.15).
- The reduced bar applies only at the first month end after the battle; it expires after that.
- Only the legitimate owner gets Counterplate. A team holding an area by early turnover doesn't.
- A team holding an area by early turnover counts as owning it for the weekly check-in perk.
- One time zone (America/New_York) for the NJ launch.
