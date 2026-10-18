import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ApiClient, ReviewBootstrap } from "../lib/contracts";
const storage = vi.hoisted(() => new Map<string, unknown>());
vi.mock("idb-keyval", () => ({
  get: async (key: string) => storage.get(key),
  set: async (key: string, value: unknown) => { storage.set(key, value); },
  del: async (key: string) => { storage.delete(key); },
  keys: async () => [...storage.keys()],
  delMany: async (keys: string[]) => { keys.forEach(key => storage.delete(key)); },
}));
import { activateAuthGeneration } from "../lib/authGeneration";
import { clearAllRecovery } from "../lib/recovery";
import { LessonView } from "./LessonView";

const bootstrap: ReviewBootstrap = {
  ok: true, ruleVersion: "english_v3", state: "open", learningDate: "2026-10-18",
  session: { id: "logout-session", revision: 1, maxQuestions: 1, status: "open" },
  questions: [{ id: "question", position: 1, phase: "review", answerForm: "chunk", phraseId: "phrase", candidateId: null, questionType: "whole_recall", promptZh: "写一个表达", promptEn: null, expectedAnswers: ["set aside time"], acceptedVariants: [], semanticBoundary: null, contentHash: "hash", draft: null }],
  lesson: { id: "lesson", theme: "life", sequence: 1, material: null, readingStarted: false, readingCompleted: false, readingSeconds: 0, burden: null },
};
beforeEach(async () => { await clearAllRecovery(); activateAuthGeneration("owner"); storage.clear(); });
afterEach(cleanup);

it("does not restore a cleared draft when the lesson checkpoint completes after logout", async () => {
  let finishCheckpoint!: (value: unknown) => void;
  const api = { checkpointAnswers: vi.fn(() => new Promise(done => { finishCheckpoint = done; })) } as unknown as ApiClient;
  const onSubmitted = vi.fn(), onRefresh = vi.fn();
  const view = render(<LessonView api={api} bootstrap={bootstrap} onSubmitted={onSubmitted} onRefresh={onRefresh}/>);
  fireEvent.change(await screen.findByRole("textbox"), { target: { value: "my private answer" } });
  fireEvent.click(screen.getByRole("button", { name: "保存并看参考" }));
  await waitFor(() => expect(api.checkpointAnswers).toHaveBeenCalledTimes(1));
  expect(storage.has("english-review:v1:logout-session")).toBe(true);
  await act(async () => { await clearAllRecovery(); });
  view.unmount();
  expect(storage.size).toBe(0);
  await act(async () => { finishCheckpoint({ ok: true, revision: 2 }); });
  expect(storage.size).toBe(0);
  expect(onSubmitted).not.toHaveBeenCalled(); expect(onRefresh).not.toHaveBeenCalled();
});
