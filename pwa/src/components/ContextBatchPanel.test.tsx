import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, it, vi } from "vitest";
import { demoApi } from "../lib/demoApi";
import { ContextBatchPanel } from "./ContextBatchPanel";
import { CHATGPT_COMMAND } from "./AiJobPanel";
import type { AiJob } from "../lib/contracts";
afterEach(cleanup);
const job = (id: string): AiJob => ({ok:true,jobId:`job-${id}`,subjectId:id,kind:"context_extract",snapshotHash:"hash",batchId:"batch",expectedCount:6,status:"prepared"});
it("reads automatically queued work and copies without a preparation click", async () => {
  const api={...demoApi,getPendingAiJobs:vi.fn(async()=>({ok:true,items:[job("a"),job("b")]})),createAiJob:vi.fn()};
  const user=userEvent.setup();
  render(<ContextBatchPanel api={api} contextIds={["a","b"]} onRefresh={vi.fn(async()=>{})}/>);
  await screen.findByText("已有 2 条语料等待 ChatGPT 处理。");
  const button=screen.getByRole("button",{name:"复制给 ChatGPT"});
  await waitFor(()=>expect((button as HTMLButtonElement).disabled).toBe(false));
  await user.click(button);
  expect(await navigator.clipboard.readText()).toBe(CHATGPT_COMMAND);
  expect(api.createAiJob).not.toHaveBeenCalled();
  expect(screen.queryByRole("button",{name:/整理/})).toBeNull();
});
it("keeps the unified command available before the scheduled job exists",async()=>{
  const api={...demoApi,getPendingAiJobs:vi.fn(async()=>({ok:true,items:[]})),createAiJob:vi.fn()};
  render(<ContextBatchPanel api={api} contextIds={["new"]} onRefresh={vi.fn(async()=>{})}/>);
  const button=await screen.findByRole("button",{name:"复制给 ChatGPT"});
  await waitFor(()=>expect((button as HTMLButtonElement).disabled).toBe(false));
  expect(screen.getByRole("textbox").getAttribute("readonly")).not.toBeNull();
  expect(api.createAiJob).not.toHaveBeenCalled();
});
