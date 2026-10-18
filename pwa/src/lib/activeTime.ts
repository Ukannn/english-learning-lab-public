/** Only foreground, engaged time counts. Waiting for AI/network never counts. */
export class ActiveTime {
  private lastTick: number;
  private lastInteraction: number;
  constructor(now = Date.now()) { this.lastTick = now; this.lastInteraction = now; }
  interact(now = Date.now()) { this.lastInteraction = now; }
  sample(eligible: boolean, now = Date.now()): { startedAt: number; endedAt: number; seconds: number } | null {
    const start = this.lastTick;
    this.lastTick = now;
    const end = Math.min(now, this.lastInteraction + 60_000);
    if (!eligible || end <= start) return null;
    return { startedAt: start, endedAt: end, seconds: (end - start) / 1000 };
  }
  tick(eligible: boolean, now = Date.now()): number {
    return this.sample(eligible, now)?.seconds ?? 0;
  }
}
