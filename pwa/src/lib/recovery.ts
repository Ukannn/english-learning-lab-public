import { del, get, set, keys, delMany } from "idb-keyval";
import type { ApiClient, CheckpointAnswer } from "./contracts";
import { assertAuthGeneration, captureAuthGeneration, invalidateAuthGeneration, isAuthGenerationCurrent } from "./authGeneration";

export interface RecoveryState {
  sessionId: string;
  sessionRevision: number;
  answers: CheckpointAnswer[];
  checkpointedPositions: number[];
  updatedAt: string;
  hintCounts?: Record<number, number>;
  learnedPositions?: number[];
  lessonWork?: { inputs: Record<number,string>; seconds: Record<string,number>; readingSecondsByDate?: Record<string, number>; skipped?: number[] };
  reviewWork?: { inputs: Record<number, string> };
}
const key = (sessionId: string) => `english-review:v1:${sessionId}`;
let writes: Promise<void> = Promise.resolve();
let cleanup: Promise<void> = Promise.resolve();

// All IndexedDB mutations share one queue. An already-started write finishes before
// logout's deletion; writes waiting in component chains still carry their old lease.
function enqueueWrite(work: () => Promise<void>): Promise<void> {
  const result = writes.catch(() => undefined).then(work);
  writes = result.catch(() => undefined);
  return result;
}
function writeForGeneration(expected: number, work: () => Promise<void>): Promise<void> {
  return enqueueWrite(async () => { assertAuthGeneration(expected); await work(); });
}
export function waitForRecoveryCleanup(): Promise<void> { return cleanup; }

export async function loadRecovery(sessionId: string, expected = captureAuthGeneration()): Promise<RecoveryState | null> {
  // Unsynced answers must not expire silently; cleanup occurs after submission or explicit logout.
  assertAuthGeneration(expected);
  const state = await get<RecoveryState>(key(sessionId)) ?? null;
  assertAuthGeneration(expected);
  return state;
}
export function saveRecovery(state: RecoveryState, expected = captureAuthGeneration()): Promise<void> {
  return writeForGeneration(expected, () => set(key(state.sessionId), state));
}
export function clearRecovery(sessionId: string, expected = captureAuthGeneration()): Promise<void> {
  return writeForGeneration(expected, () => del(key(sessionId)));
}
export function clearAllRecovery(): Promise<void> {
  // Invalidate synchronously, before waiting for the auth network or IndexedDB.
  invalidateAuthGeneration();
  cleanup = enqueueWrite(async () => {
    const all = await keys();
    await delMany(all.filter(item => typeof item === "string" && item.startsWith("english-review:")));
    for (const storageKey of Object.keys(localStorage)) if (storageKey.startsWith("english-review:")) localStorage.removeItem(storageKey);
    for (const storageKey of Object.keys(sessionStorage)) if (storageKey.startsWith("english-review-position:")) sessionStorage.removeItem(storageKey);
  });
  return cleanup;
}
interface PendingActivity { sessionId: string; position: number; action: "hint" | "study" | "reveal"; idempotencyKey: string }
export async function recordActivity(client: ApiClient, sessionId: string, position: number, action: PendingActivity["action"], ordinal = 1, expected = captureAuthGeneration()): Promise<void> {
  const idempotencyKey = `activity:${sessionId}:${position}:${action}:${ordinal}`;
  const storageKey = `english-review:activity:${idempotencyKey}`;
  const activity = { sessionId, position, action, idempotencyKey };
  await writeForGeneration(expected, () => set(storageKey, activity));
  assertAuthGeneration(expected);
  try {
    await client.recordQuestionActivity(sessionId, position, action, idempotencyKey);
    await writeForGeneration(expected, () => del(storageKey));
  } catch (error) {
    if (!isAuthGenerationCurrent(expected)) throw error;
    // An ordinary network failure stays queued until synchronization succeeds.
  }
}
export async function syncPendingActivities(client: ApiClient, expected = captureAuthGeneration()): Promise<void> {
  assertAuthGeneration(expected);
  const activityKeys = (await keys()).filter(item => typeof item === "string" && item.startsWith("english-review:activity:"));
  for (const storageKey of activityKeys) {
    assertAuthGeneration(expected);
    const item = await get<PendingActivity>(storageKey);
    assertAuthGeneration(expected);
    if (!item) continue;
    await client.recordQuestionActivity(item.sessionId, item.position, item.action, item.idempotencyKey);
    await writeForGeneration(expected, () => del(storageKey));
  }
}
