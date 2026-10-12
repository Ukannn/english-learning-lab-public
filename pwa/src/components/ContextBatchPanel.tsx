import { CopyButton } from "./CopyButton";
import { useEffect, useRef, useState } from "react";
import type { AiJob, ApiClient } from "../lib/contracts";
import { CHATGPT_COMMAND } from "./AiJobPanel";

type Props = { api: ApiClient; contextIds: string[]; onRefresh(): Promise<void> };
export function ContextBatchPanel({ api, contextIds, onRefresh }: Props) {
  const [jobs, setJobs] = useState<AiJob[]>([]);
  const [busy, setBusy] = useState(true);
  const [message, setMessage] = useState<string | null>(null);
  const locked = useRef(false);
  const refresh = useRef(onRefresh);
  refresh.current = onRefresh;
  useEffect(() => {
    let disposed = false;
    async function check() {
      if (locked.current) return;
      locked.current = true;
      try {
        const result = await api.getPendingAiJobs();
        if (!disposed) {
          setJobs(result.items.filter(job => job.kind === "context_extract"));
          await refresh.current();
        }
      } catch (error) {
        if (!disposed) setMessage(error instanceof Error ? error.message : "读取处理进度失败，请重试。");
      } finally { locked.current = false; if (!disposed) setBusy(false); }
    }
    void check();
    const timer = window.setInterval(() => void check(), 10000);
    const focus = () => void check();
    window.addEventListener("focus", focus);
    return () => { disposed = true; window.clearInterval(timer); window.removeEventListener("focus", focus); };
  }, [api]);

  const remaining = contextIds.filter(id => !jobs.some(job => job.subjectId === id)).length;
  return <section className="prompt-box card">
    <h2>整理语料</h2>
    <p>语料每天北京时间 04:00 自动排队，ChatGPT 处理待办时也会补齐。整理后，在「待确认」中确认表达。</p>
    {(jobs.length > 0 || remaining > 0) && <>{jobs.length > 0 && <p>已有 {jobs.length} 条语料等待 ChatGPT 处理。</p>}<label className="answer-field"><span>发给 ChatGPT 的指令</span><textarea readOnly rows={2} value={CHATGPT_COMMAND}/></label><CopyButton text={CHATGPT_COMMAND} label="复制给 ChatGPT" disabled={busy} onCopied={() => setMessage("已复制，请发给已连接 Supabase 的 ChatGPT。整理结果会自动更新。")} onError={() => setMessage("无法自动复制，请选中指令后复制。")}/></>}
    {!busy && !remaining && !jobs.length && <p>当前语料已整理完成。</p>}
    {message && <p role="status" className="status-message">{message}</p>}
  </section>;
}
