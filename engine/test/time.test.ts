import { test } from "node:test";
import assert from "node:assert/strict";
import { dayKey, monthKey, startOfNextMonth, weekKey } from "../src/time.ts";
import { TZ, t } from "./helpers.ts";

test("day and month keys use New Jersey local time, not UTC", () => {
  // 11:30 PM on Nov 30 in NJ is already Dec 1 in UTC.
  const late = t(2026, 11, 30, 23, 30);
  assert.equal(dayKey(late, TZ), "2026-11-30");
  assert.equal(monthKey(late, TZ), "2026-11");
});

test("weeks start on Sunday and run across a month change", () => {
  // 2026-11-29 is a Sunday; Dec 1 and 2 are in the same week.
  assert.equal(weekKey(t(2026, 11, 29), TZ), "2026-11-29");
  assert.equal(weekKey(t(2026, 12, 2), TZ), "2026-11-29");
  assert.equal(weekKey(t(2026, 11, 28), TZ), "2026-11-22");
});

test("month boundary is local midnight, through daylight saving changes", () => {
  assert.equal(startOfNextMonth("2026-11", TZ), t(2026, 12, 1, 0));
  assert.equal(startOfNextMonth("2027-03", TZ), t(2027, 4, 1, 0));
  assert.equal(startOfNextMonth("2026-12", TZ), t(2027, 1, 1, 0));
});
