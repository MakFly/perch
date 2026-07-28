import { describe, expect, test } from "bun:test";

import { dailyActivity, rankBuilders, rankGuilds, splitByModel, type DayFact } from "../src/aggregate.js";
import type { BuilderPublic } from "../src/types.js";

function builder(handle: string, team: string | null = null): BuilderPublic {
  return { handle, displayName: handle, avatarUrl: null, team, agent: "claude" };
}

function fact(overrides: Partial<DayFact> & Pick<DayFact, "handle">): DayFact {
  return {
    day: "2026-07-27",
    model: "Opus 5",
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    costUsd: 0,
    focusSeconds: 0,
    sessions: 0,
    ...overrides,
  };
}

const cast = new Map([
  ["ada", builder("ada", "Nimbus")],
  ["bo", builder("bo", "Nimbus")],
  ["cy", builder("cy")],
]);

describe("ranking", () => {
  test("orders by output tokens, not by total", () => {
    // `cy` reads a much bigger repository but produces less. Ranking on total tokens
    // would reward opening large files.
    const rows = rankBuilders(
      [
        fact({ handle: "ada", outputTokens: 500 }),
        fact({ handle: "cy", outputTokens: 100, cacheReadTokens: 10_000_000 }),
      ],
      cast,
    );
    expect(rows.map((row) => row.handle)).toEqual(["ada", "cy"]);
  });

  test("a tie breaks on cost, then on handle, so two calls agree", () => {
    const rows = rankBuilders(
      [
        fact({ handle: "bo", outputTokens: 100, costUsd: 1 }),
        fact({ handle: "ada", outputTokens: 100, costUsd: 1 }),
        fact({ handle: "cy", outputTokens: 100, costUsd: 9 }),
      ],
      cast,
    );
    expect(rows.map((row) => row.handle)).toEqual(["cy", "ada", "bo"]);
    expect(rows.map((row) => row.rank)).toEqual([1, 2, 3]);
  });

  test("the model column names the one that produced most of the output", () => {
    const rows = rankBuilders(
      [
        fact({ handle: "ada", model: "Sonnet 5", outputTokens: 10 }),
        fact({ handle: "ada", model: "Opus 5", outputTokens: 90 }),
      ],
      cast,
    );
    expect(rows[0]!.model).toBe("Opus 5");
  });

  test("sessions are counted per day, not once per model touched that day", () => {
    const rows = rankBuilders(
      [
        fact({ handle: "ada", model: "Opus 5", day: "2026-07-27", sessions: 3, outputTokens: 1 }),
        fact({ handle: "ada", model: "Sonnet 5", day: "2026-07-27", sessions: 3, outputTokens: 1 }),
        fact({ handle: "ada", model: "Opus 5", day: "2026-07-28", sessions: 2, outputTokens: 1 }),
      ],
      cast,
    );
    expect(rows[0]!.sessions).toBe(5);
  });

  test("a builder with facts but no public row is left out of the board", () => {
    const rows = rankBuilders([fact({ handle: "ghost", outputTokens: 999 })], cast);
    expect(rows).toEqual([]);
  });
});

describe("guilds", () => {
  test("teams roll up their members and someone with no team is not a guild of one", () => {
    const rows = rankBuilders(
      [
        fact({ handle: "ada", outputTokens: 100, costUsd: 2 }),
        fact({ handle: "bo", outputTokens: 50, costUsd: 1 }),
        fact({ handle: "cy", outputTokens: 400, costUsd: 4 }),
      ],
      cast,
    );
    const guilds = rankGuilds(rows);
    expect(guilds).toHaveLength(1);
    expect(guilds[0]).toMatchObject({ team: "Nimbus", members: 2, outputTokens: 150, costUsd: 3 });
  });
});

describe("model split", () => {
  test("cache traffic is folded into input, and rows are ordered by cost", () => {
    const split = splitByModel([
      fact({ handle: "ada", model: "Opus 5", inputTokens: 10, cacheReadTokens: 5, costUsd: 1 }),
      fact({ handle: "ada", model: "Fable 5", inputTokens: 1, costUsd: 7 }),
    ]);
    expect(split.map((row) => row.model)).toEqual(["Fable 5", "Opus 5"]);
    expect(split[1]!.inputTokens).toBe(15);
  });
});

describe("daily activity", () => {
  test("every day in the window gets a cell, including the empty ones", () => {
    const days = dailyActivity(
      [fact({ handle: "ada", day: "2026-07-29", outputTokens: 5 })],
      "2026-07-27",
      "2026-07-30",
    );
    expect(days.map((day) => day.day)).toEqual([
      "2026-07-27",
      "2026-07-28",
      "2026-07-29",
      "2026-07-30",
    ]);
    expect(days.map((day) => day.tokens)).toEqual([0, 0, 5, 0]);
  });
});
