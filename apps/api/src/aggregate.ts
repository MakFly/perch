/**
 * Turning rows into a board.
 *
 * Both repositories share this: Postgres hands over the same shape the demo set holds in
 * memory, so ranking, tie-breaks and the model split are written once and tested once
 * rather than diverging between the two.
 */

import { addDays, longestStreak, parseISODate, toISODate } from "./period.js";
import type {
  ActivityDay,
  BuilderPublic,
  GuildRow,
  LeaderboardRow,
  ModelSplit,
} from "./types.js";

export interface DayFact {
  handle: string;
  day: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  costUsd: number;
  focusSeconds: number;
  sessions: number;
}

export function totalTokens(fact: DayFact): number {
  return fact.inputTokens + fact.outputTokens + fact.cacheReadTokens + fact.cacheWriteTokens;
}

/**
 * Rank builders over a set of daily facts.
 *
 * Ordered by output tokens, because that is the only number the model actually produced —
 * input and cache reads are a function of how big the repository is, and ranking on them
 * would reward opening large files. Ties break on cost, then on handle, so the order is
 * stable across two calls with identical data.
 */
export function rankBuilders(
  facts: DayFact[],
  builders: Map<string, BuilderPublic>,
): LeaderboardRow[] {
  interface Accumulator {
    outputTokens: number;
    totalTokens: number;
    costUsd: number;
    focusSeconds: number;
    sessions: number;
    perModel: Map<string, number>;
  }

  const byBuilder = new Map<string, Accumulator>();
  // A day's session count is per-day, not per-model: summing the model rows would count
  // one session once for every model it touched.
  const sessionsSeen = new Map<string, Map<string, number>>();

  for (const fact of facts) {
    let accumulator = byBuilder.get(fact.handle);
    if (!accumulator) {
      accumulator = {
        outputTokens: 0,
        totalTokens: 0,
        costUsd: 0,
        focusSeconds: 0,
        sessions: 0,
        perModel: new Map(),
      };
      byBuilder.set(fact.handle, accumulator);
    }
    accumulator.outputTokens += fact.outputTokens;
    accumulator.totalTokens += totalTokens(fact);
    accumulator.costUsd += fact.costUsd;
    accumulator.focusSeconds += fact.focusSeconds;
    accumulator.perModel.set(
      fact.model,
      (accumulator.perModel.get(fact.model) ?? 0) + fact.outputTokens,
    );

    let days = sessionsSeen.get(fact.handle);
    if (!days) {
      days = new Map();
      sessionsSeen.set(fact.handle, days);
    }
    days.set(fact.day, Math.max(days.get(fact.day) ?? 0, fact.sessions));
  }

  for (const [handle, days] of sessionsSeen) {
    const accumulator = byBuilder.get(handle);
    if (!accumulator) continue;
    accumulator.sessions = [...days.values()].reduce((sum, value) => sum + value, 0);
  }

  const rows = [...byBuilder.entries()]
    .filter(([handle]) => builders.has(handle))
    .map(([handle, accumulator]) => {
      const builder = builders.get(handle)!;
      return {
        ...builder,
        rank: 0,
        model: dominantModel(accumulator.perModel),
        outputTokens: accumulator.outputTokens,
        totalTokens: accumulator.totalTokens,
        costUsd: round2(accumulator.costUsd),
        focusSeconds: accumulator.focusSeconds,
        sessions: accumulator.sessions,
      } satisfies LeaderboardRow;
    })
    .sort(
      (a, b) =>
        b.outputTokens - a.outputTokens ||
        b.costUsd - a.costUsd ||
        a.handle.localeCompare(b.handle),
    );

  rows.forEach((row, index) => {
    row.rank = index + 1;
  });
  return rows;
}

function dominantModel(perModel: Map<string, number>): string {
  let best = "—";
  let bestTokens = -1;
  for (const [model, tokens] of [...perModel].sort((a, b) => a[0].localeCompare(b[0]))) {
    if (tokens > bestTokens) {
      best = model;
      bestTokens = tokens;
    }
  }
  return best;
}

/** Roll individual rows up into teams. Builders with no team are not a guild of one. */
export function rankGuilds(rows: LeaderboardRow[]): GuildRow[] {
  const byTeam = new Map<string, GuildRow>();
  for (const row of rows) {
    const team = row.team?.trim();
    if (!team) continue;
    const existing = byTeam.get(team) ?? {
      rank: 0,
      team,
      members: 0,
      outputTokens: 0,
      costUsd: 0,
      focusSeconds: 0,
      sessions: 0,
    };
    existing.members += 1;
    existing.outputTokens += row.outputTokens;
    existing.costUsd += row.costUsd;
    existing.focusSeconds += row.focusSeconds;
    existing.sessions += row.sessions;
    byTeam.set(team, existing);
  }
  const guilds = [...byTeam.values()].sort(
    (a, b) => b.outputTokens - a.outputTokens || a.team.localeCompare(b.team),
  );
  guilds.forEach((guild, index) => {
    guild.rank = index + 1;
    guild.costUsd = round2(guild.costUsd);
  });
  return guilds;
}

export function splitByModel(facts: DayFact[]): ModelSplit[] {
  const byModel = new Map<string, ModelSplit>();
  for (const fact of facts) {
    const existing = byModel.get(fact.model) ?? {
      model: fact.model,
      inputTokens: 0,
      outputTokens: 0,
      costUsd: 0,
    };
    existing.inputTokens += fact.inputTokens + fact.cacheReadTokens + fact.cacheWriteTokens;
    existing.outputTokens += fact.outputTokens;
    existing.costUsd += fact.costUsd;
    byModel.set(fact.model, existing);
  }
  return [...byModel.values()]
    .map((split) => ({ ...split, costUsd: round2(split.costUsd) }))
    .sort((a, b) => b.costUsd - a.costUsd || a.model.localeCompare(b.model));
}

/**
 * Daily buckets covering `[from, to]` with no holes.
 *
 * The heatmap needs a cell for every day including the empty ones — a calendar that skips
 * the days you did nothing is not a calendar.
 */
export function dailyActivity(facts: DayFact[], from: string, to: string): ActivityDay[] {
  const byDay = new Map<string, ActivityDay>();
  for (const fact of facts) {
    const existing = byDay.get(fact.day) ?? { day: fact.day, tokens: 0, costUsd: 0 };
    existing.tokens += totalTokens(fact);
    existing.costUsd += fact.costUsd;
    byDay.set(fact.day, existing);
  }

  const out: ActivityDay[] = [];
  const end = parseISODate(to).getTime();
  for (let cursor = parseISODate(from); cursor.getTime() <= end; cursor = addDays(cursor, 1)) {
    const day = toISODate(cursor);
    const found = byDay.get(day);
    out.push({ day, tokens: found?.tokens ?? 0, costUsd: round2(found?.costUsd ?? 0) });
  }
  return out;
}

export function activeDays(facts: DayFact[]): string[] {
  return [...new Set(facts.filter((fact) => totalTokens(fact) > 0).map((fact) => fact.day))].sort();
}

export function streakOf(facts: DayFact[]): number {
  return longestStreak(activeDays(facts));
}

export function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
