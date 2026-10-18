import { addLearningDays, learningDateAt } from "./learningDate";

export type ReadingSecondsByDate = Record<string, number>;
export const MAX_READING_SECONDS = 7200;

export function sumReadingSeconds(buckets: ReadingSecondsByDate = {}): number {
  return Object.values(buckets).reduce((sum, seconds) => sum + seconds, 0);
}

// The interval comes from the engaged-time clock, including its idle cutoff.
// Split it at Shanghai midnight; do not date an old interval by the time it syncs.
export function addReadingInterval(buckets: ReadingSecondsByDate, startedAt: number, endedAt: number): void {
  let cursor = startedAt;
  while (cursor < endedAt) {
    const day = learningDateAt(new Date(cursor));
    const midnight = new Date(`${addLearningDays(day, 1)}T00:00:00+08:00`).getTime();
    const end = Math.min(endedAt, midnight);
    buckets[day] = (buckets[day] ?? 0) + (end - cursor) / 1000;
    cursor = end;
  }
}

export function wholeReadingSeconds(buckets: ReadingSecondsByDate): ReadingSecondsByDate {
  return Object.fromEntries(Object.entries(buckets).filter(([, seconds]) => seconds >= 1)
    .map(([day, seconds]) => [day, Math.floor(seconds)]));
}

// One lesson retains its existing two-hour recording budget. Undated history is
// kept first; dated evidence then fills that budget in actual date order. Never
// move an overflow second to another date, or send a total smaller than its dates.
export function normalizeReadingTime(total: number, byDate: ReadingSecondsByDate = {}) {
  const whole = wholeReadingSeconds(byDate);
  const unallocated = Math.min(MAX_READING_SECONDS, Math.max(0, Math.floor(total) - sumReadingSeconds(whole)));
  let remaining = MAX_READING_SECONDS - unallocated;
  const bounded: ReadingSecondsByDate = {};
  for (const day of Object.keys(whole).sort()) {
    const kept = Math.min(whole[day], remaining);
    if (kept > 0) bounded[day] = kept;
    remaining -= kept;
  }
  return { seconds: MAX_READING_SECONDS - remaining, byDate: bounded };
}

export function recordReadingInterval(buckets: ReadingSecondsByDate, fractions: ReadingSecondsByDate,
  startedAt: number, endedAt: number, remaining: number): number {
  addReadingInterval(fractions, startedAt, endedAt);
  let recorded = 0;
  for (const [day, seconds] of Object.entries(fractions)) {
    const whole = Math.min(Math.floor(seconds), remaining - recorded);
    if (whole <= 0) continue;
    buckets[day] = (buckets[day] ?? 0) + whole;
    fractions[day] -= whole;
    recorded += whole;
  }
  return recorded;
}

export function mergeReadingTime(localSeconds = 0, local: ReadingSecondsByDate = {}, cloudSeconds = 0, cloud: ReadingSecondsByDate = {}) {
  local = wholeReadingSeconds(local);
  cloud = wholeReadingSeconds(cloud);
  const byDate = { ...cloud };
  for (const [day, seconds] of Object.entries(local)) byDate[day] = Math.max(byDate[day] ?? 0, seconds);
  // Legacy totals have no dated evidence. Keep that remainder separate, including
  // when a dated client resumes an old package or merges another device's work.
  const unallocated = Math.max(0, Math.floor(localSeconds) - sumReadingSeconds(local), Math.floor(cloudSeconds) - sumReadingSeconds(cloud));
  return normalizeReadingTime(unallocated + sumReadingSeconds(byDate), byDate);
}
