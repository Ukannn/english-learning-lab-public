import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiClient } from "./contracts";

const store = vi.hoisted(() => ({ values: new Map<string, unknown>(), beforeSet: null as null | (() => Promise<void>) }));
vi.mock("idb-keyval", () => ({
  get: vi.fn(async (key: string) => store.values.get(key)),
  set: vi.fn(async (key: string, value: unknown) => { await store.beforeSet?.(); store.values.set(key, value); }),
  del: vi.fn(async (key: string) => { store.values.delete(key); }),
  keys: vi.fn(async () => [...store.values.keys()]),
  delMany: vi.fn(async (keys: string[]) => { keys.forEach(key => store.values.delete(key)); }),
}));
import { set } from "idb-keyval";
import { activateAuthGeneration, captureAuthGeneration, isAuthGenerationCurrent, scopeApiClient } from "./authGeneration";
import { clearAllRecovery, recordActivity, saveRecovery, syncPendingActivities } from "./recovery";

function deferred<T = void>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
const draft = (answer: string) => ({ sessionId: "same-session", sessionRevision: 1, answers: [], checkpointedPositions: [], updatedAt: answer });

beforeEach(async () => {
  store.beforeSet = null;
  await clearAllRecovery();
  activateAuthGeneration("owner");
  store.values.clear(); localStorage.clear(); sessionStorage.clear(); vi.clearAllMocks();
});

describe("authentication-scoped recovery", () => {
  it("drains an in-flight IndexedDB write and rejects queued old writes before cleanup resolves", async () => {
    const gate = deferred();
    store.beforeSet = () => gate.promise;
    const oldGeneration = captureAuthGeneration();
    const first = saveRecovery(draft("first"), oldGeneration);
    await vi.waitFor(() => expect(set).toHaveBeenCalledTimes(1));
    const queued = saveRecovery(draft("queued"), oldGeneration).catch(error => error);
    const clearing = clearAllRecovery();
    expect(isAuthGenerationCurrent(oldGeneration)).toBe(false);
    gate.resolve();
    await first; await clearing;
    expect(await queued).toHaveProperty("name", "AuthGenerationExpired");
    expect(store.values.size).toBe(0);
    expect(set).toHaveBeenCalledTimes(1);
  });

  it("does not let a late old save overwrite a fresh login's draft", async () => {
    const oldGeneration = captureAuthGeneration();
    await saveRecovery(draft("old"), oldGeneration);
    await clearAllRecovery(); activateAuthGeneration("owner");
    await saveRecovery(draft("new"), captureAuthGeneration());
    await expect(saveRecovery(draft("late old"), oldGeneration)).rejects.toHaveProperty("name", "AuthGenerationExpired");
    expect(store.values.get("english-review:v1:same-session")).toMatchObject({ updatedAt: "new" });
  });

  it("prevents an old activity completion from deleting or recreating a new login's activity", async () => {
    const gate = deferred<{ ok: boolean }>();
    const client = { recordQuestionActivity: vi.fn(() => gate.promise) } as unknown as ApiClient;
    const pending = recordActivity(client, "same-session", 1, "hint", 1, captureAuthGeneration()).catch(error => error);
    await vi.waitFor(() => expect(client.recordQuestionActivity).toHaveBeenCalledTimes(1));
    await clearAllRecovery(); activateAuthGeneration("owner");
    const key = "english-review:activity:activity:same-session:1:hint:1";
    store.values.set(key, { from: "new login" });
    gate.resolve({ ok: true });
    expect(await pending).toHaveProperty("name", "AuthGenerationExpired");
    expect(store.values.get(key)).toEqual({ from: "new login" });
  });

  it("cannot send queued activities or a new RPC using an invalidated component scope", async () => {
    const oldGeneration = captureAuthGeneration();
    const client = { recordQuestionActivity: vi.fn(), getDashboard: vi.fn() } as unknown as ApiClient;
    const scoped = scopeApiClient(client, oldGeneration);
    await clearAllRecovery(); activateAuthGeneration("owner");
    await expect(syncPendingActivities(client, oldGeneration)).rejects.toHaveProperty("name", "AuthGenerationExpired");
    await expect(scoped.getDashboard()).rejects.toHaveProperty("name", "AuthGenerationExpired");
    expect(client.recordQuestionActivity).not.toHaveBeenCalled();
    expect(client.getDashboard).not.toHaveBeenCalled();
  });

  it("rejects an RPC result that arrives after logout even when the request already succeeded remotely", async () => {
    const gate = deferred<unknown>();
    const client = { getDashboard: vi.fn(() => gate.promise) } as unknown as ApiClient;
    const response = scopeApiClient(client, captureAuthGeneration()).getDashboard().catch(error => error);
    await clearAllRecovery(); activateAuthGeneration("owner");
    gate.resolve({ ok: true });
    expect(await response).toHaveProperty("name", "AuthGenerationExpired");
  });
});
