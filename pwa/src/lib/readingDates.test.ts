import { describe, expect, it } from "vitest";
import { ActiveTime } from "./activeTime";
import { addReadingInterval, mergeReadingTime, normalizeReadingTime, recordReadingInterval, sumReadingSeconds, wholeReadingSeconds } from "./readingDates";

describe("dated reading evidence", () => {
  it("splits engaged reading at Shanghai midnight", () => {
    const buckets = {};
    addReadingInterval(buckets, Date.parse("2026-10-17T15:59:58.750Z"), Date.parse("2026-10-17T16:00:02Z"));
    expect(buckets).toEqual({ "2026-10-17": 1.25, "2026-10-18": 2 });
  });

  it("dates an idle cutoff by when the interval occurred, even if the tick arrives tomorrow", () => {
    const start = Date.parse("2026-10-17T15:58:00Z");
    const interval = new ActiveTime(start).sample(true, Date.parse("2026-10-17T16:01:00Z"))!;
    const buckets = {};
    addReadingInterval(buckets, interval.startedAt, interval.endedAt);
    expect(buckets).toEqual({ "2026-10-17": 60 });
  });

  it("preserves a legacy total without assigning an invented date", () => {
    expect(mergeReadingTime(0, {}, 75, {})).toEqual({ seconds: 75, byDate: {} });
    expect(mergeReadingTime(85, { "2026-10-18": 10 }, 75, {}))
      .toEqual({ seconds: 85, byDate: { "2026-10-18": 10 } });
  });

  it("merges cumulative dates once while retaining each device's separate-day progress", () => {
    const reading = mergeReadingTime(95, { "2026-10-18": 20 }, 105, { "2026-10-17": 30 });
    expect(reading).toEqual({ seconds: 125, byDate: { "2026-10-17": 30, "2026-10-18": 20 } });
    expect(mergeReadingTime(reading.seconds, reading.byDate, reading.seconds, reading.byDate)).toEqual(reading);
  });

  it("keeps a larger unsynced legacy baseline when the cloud already has other dated reading", () => {
    const expected = { seconds: 125, byDate: { "2026-10-17": 20, "2026-10-18": 10 } };
    expect(mergeReadingTime(105, { "2026-10-18": 10 }, 95, { "2026-10-17": 20 })).toEqual(expected);
    expect(mergeReadingTime(95, { "2026-10-17": 20 }, 105, { "2026-10-18": 10 })).toEqual(expected);
  });

  it("caps two offline days together and keeps the same dates after swapping devices or replaying", () => {
    const first = { "2026-10-17": 6000 }, second = { "2026-10-18": 6000 };
    const expected = { seconds: 7200, byDate: { "2026-10-17": 6000, "2026-10-18": 1200 } };
    expect(mergeReadingTime(6000, first, 6000, second)).toEqual(expected);
    expect(mergeReadingTime(6000, second, 6000, first)).toEqual(expected);
    expect(mergeReadingTime(6000, second, expected.seconds, expected.byDate)).toEqual(expected);
    expect(normalizeReadingTime(12000, { ...first, ...second })).toEqual(expected);
  });

  it("reserves the old undated budget before retaining dated seconds without changing their dates", () => {
    expect(mergeReadingTime(6000, { "2026-10-18": 6000 }, 7100, { "2026-10-17": 100 }))
      .toEqual({ seconds: 7200, byDate: { "2026-10-17": 100, "2026-10-18": 100 } });
    expect(normalizeReadingTime(9000, {})).toEqual({ seconds: 7200, byDate: {} });
  });

  it("serializes whole seconds without moving fractional or unknown time to a different date", () => {
    const byDate = wholeReadingSeconds({ "2026-10-17": 1.9, "2026-10-18": 2.8, "2026-10-19": .2 });
    expect(byDate).toEqual({ "2026-10-17": 1, "2026-10-18": 2 });
    expect(sumReadingSeconds(byDate)).toBe(3);
  });

  it("carries fractional seconds within their date without creating an undated legacy remainder", () => {
    const buckets = {}, fractions = {};
    const midnight = Date.parse("2026-10-17T16:00:00Z");
    expect(recordReadingInterval(buckets, fractions, midnight - 500, midnight + 500, 7200)).toBe(0);
    expect(buckets).toEqual({});
    expect(recordReadingInterval(buckets, fractions, midnight + 500, midnight + 1200, 7200)).toBe(1);
    expect(buckets).toEqual({ "2026-10-18": 1 });
    expect(mergeReadingTime(1, buckets, 0, {})).toEqual({ seconds: 1, byDate: buckets });
  });
});
