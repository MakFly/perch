import { describe, expect, test } from "bun:test";

import { longestStreak, profileRangeStart, resolvePeriod, startOfISOWeek, toISODate } from "../src/period.js";

describe("ISO weeks", () => {
  test("a Tuesday belongs to the week that started on Monday", () => {
    // 2026-07-28 is a Tuesday; the reference board labels that week 27 juil. – 2 août.
    expect(toISODate(startOfISOWeek(new Date("2026-07-28T09:00:00Z")))).toBe("2026-07-27");
  });

  test("a Sunday belongs to the week that started six days earlier, not the next one", () => {
    expect(toISODate(startOfISOWeek(new Date("2026-08-02T23:00:00Z")))).toBe("2026-07-27");
  });

  test("the week period is labelled the way the board shows it", () => {
    const period = resolvePeriod("week", 0, new Date("2026-07-28T09:00:00Z"));
    expect(period).toMatchObject({
      kind: "week",
      start: "2026-07-27",
      end: "2026-08-02",
      label: "27 juil. – 2 août",
      offset: 0,
    });
  });

  test("walking back a week moves the whole window, not just its start", () => {
    const period = resolvePeriod("week", 2, new Date("2026-07-28T09:00:00Z"));
    expect(period.start).toBe("2026-07-13");
    expect(period.end).toBe("2026-07-19");
  });

  test("agents and guilds are weekly boards", () => {
    const agents = resolvePeriod("agents", 0, new Date("2026-07-28T09:00:00Z"));
    expect(agents.start).toBe("2026-07-27");
  });
});

describe("months", () => {
  test("a month period ends on the last day of that month", () => {
    const period = resolvePeriod("month", 0, new Date("2026-02-14T09:00:00Z"));
    expect(period.start).toBe("2026-02-01");
    expect(period.end).toBe("2026-02-28");
    expect(period.label).toBe("février 2026");
  });

  test("walking back from January lands in December of the year before", () => {
    const period = resolvePeriod("month", 1, new Date("2026-01-10T09:00:00Z"));
    expect(period.start).toBe("2025-12-01");
    expect(period.end).toBe("2025-12-31");
  });
});

describe("profile ranges", () => {
  test("30d includes today, so it spans 30 days and not 31", () => {
    expect(profileRangeStart("30d", new Date("2026-07-28T09:00:00Z"))).toBe("2026-06-29");
  });

  test("all has no lower bound", () => {
    expect(profileRangeStart("all")).toBeNull();
  });
});

describe("streaks", () => {
  test("consecutive days count as one run", () => {
    expect(longestStreak(["2026-07-01", "2026-07-02", "2026-07-03"])).toBe(3);
  });

  test("a gap ends the run", () => {
    expect(longestStreak(["2026-07-01", "2026-07-02", "2026-07-05", "2026-07-06"])).toBe(2);
  });

  test("no activity is a streak of zero, not of one", () => {
    expect(longestStreak([])).toBe(0);
  });

  test("a month boundary is not a gap", () => {
    expect(longestStreak(["2026-07-31", "2026-08-01"])).toBe(2);
  });
});
