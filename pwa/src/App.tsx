import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AppShell, type ViewId } from "./components/AppShell";
import { AuthGate } from "./components/AuthGate";
import { TodayView } from "./components/TodayView";
import { AnalyticsView } from "./components/AnalyticsView";
import { SettingsView } from "./components/SettingsView";
import { LibraryWorkspace, ContextView } from "./components/LibraryViews";
import { api, supabase } from "./lib/api";
import type { ApiClient, DashboardData, ReviewBootstrap } from "./lib/contracts";
import { demoApi } from "./lib/demoApi";
import { designDemoApi } from "./lib/designDemo";
import { clearAllRecovery } from "./lib/recovery";
import { captureAuthGeneration, isAuthGenerationCurrent, scopeApiClient } from "./lib/authGeneration";
import { RecordsView } from "./components/RecordsView";
import { usePhraseInventory } from "./lib/usePhraseInventory";
import { applyTheme, readThemePreference, THEME_STORAGE_KEY } from "./lib/theme";

function routeFromHash(): ViewId {
  const route = location.hash.replace(/^#\/?/, "").split(/[/?]/)[0];
  return ["today", "intake", "analytics", "history", "library", "status"].includes(route) ? route as ViewId : "today";
}
export function App() {
  const demo = import.meta.env.VITE_DEMO_MODE === "true";
  const client = useMemo(() => demo ? (new URLSearchParams(location.search).get("scenario") === "completed" ? designDemoApi : demoApi) : api, [demo]);
  return <AuthGate demo={demo}><LearningApp client={client} demo={demo} /></AuthGate>;
}

export function LearningApp({ client: sourceClient, demo }: { client: ApiClient; demo: boolean }) {
  const authGeneration = useRef(captureAuthGeneration());
  const client = useMemo(() => scopeApiClient(sourceClient, authGeneration.current), [sourceClient]);
  const [view, setView] = useState<ViewId>(routeFromHash);
  const [online, setOnline] = useState(navigator.onLine);
  const [dashboard, setDashboard] = useState<DashboardData | null>(null);
  const [bootstrap, setBootstrap] = useState<ReviewBootstrap | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [dataRevision, setDataRevision] = useState(0);
  const [signingOut, setSigningOut] = useState(false);
  const signOutPending = useRef(false);
  const [recordsQuery, setRecordsQuery] = useState(() => routeFromHash() === "history" ? location.hash.split("?")[1] ?? "" : "");
  const recordsLocation = useRef(routeFromHash() === "history" ? location.hash : "#history");
  const positions = useRef<Partial<Record<ViewId, number>>>({});
  const previousView = useRef(view);
  const inventory = usePhraseInventory(client, view === "analytics" || view === "history", dataRevision);
  const refresh = useCallback(async () => {
    if (!isAuthGenerationCurrent(authGeneration.current)) return;
    setLoading(true); setError(null);
    try {
      // The queue must be ready before dashboard totals are read.
      setBootstrap(await client.getReviewBootstrap());
      setDashboard(await client.getDashboard());
      setDataRevision(value => value + 1);
    } catch (caught) { if (isAuthGenerationCurrent(authGeneration.current)) setError(caught instanceof Error ? caught.message : "内容加载失败，请重试。"); }
    finally { if (isAuthGenerationCurrent(authGeneration.current)) setLoading(false); }
  }, [client]);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    const hash = () => {
      const next = routeFromHash();
      if (previousView.current !== next) positions.current[previousView.current] = window.scrollY;
      if (next === "history") { setRecordsQuery(location.hash.split("?")[1] ?? ""); recordsLocation.current = location.hash; }
      setView(next);
    };
    const connection = () => setOnline(navigator.onLine);
    window.addEventListener("hashchange", hash); window.addEventListener("online", connection); window.addEventListener("offline", connection);
    return () => { window.removeEventListener("hashchange", hash); window.removeEventListener("online", connection); window.removeEventListener("offline", connection); };
  }, []);
  useEffect(() => {
    const system = window.matchMedia?.("(prefers-color-scheme: dark)");
    const update = () => applyTheme(readThemePreference());
    const sync = (event: StorageEvent) => { if (event.key === THEME_STORAGE_KEY || event.key === null) update(); };
    update(); system?.addEventListener("change", update);
    window.addEventListener("storage", sync);
    return () => { system?.removeEventListener("change", update); window.removeEventListener("storage", sync); };
  }, []);
  useLayoutEffect(() => {
    previousView.current = view;
    const frame = window.requestAnimationFrame(() => {
      window.scrollTo({ top: positions.current[view] ?? 0, behavior: "instant" });
      document.getElementById("learning-content")?.focus({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [view]);
  function navigate(next: ViewId) {
    if (next === view) return;
    positions.current[view] = window.scrollY;
    location.hash = next === "history" ? recordsLocation.current : next;
    setView(next);
  }
  function updateRecordsQuery(query: string) {
    const hash = `#history${query ? `?${query}` : ""}`;
    recordsLocation.current = hash; setRecordsQuery(query);
    window.history.replaceState(window.history.state, "", hash);
  }
  async function signOut() {
    if (signOutPending.current) return;
    signOutPending.current = true; setSigningOut(true); setError(null);
    // Clear starts before the network request. Its completion must never run after
    // a later login and erase that login's new drafts.
    const cleared = clearAllRecovery();
    try { const [, result] = await Promise.all([cleared, supabase?.auth.signOut()]); if (result?.error) throw result.error; }
    catch (caught) { setError(caught instanceof Error ? caught.message : "退出失败，请重试。"); }
    finally { signOutPending.current = false; }
  }
  if (signingOut) return <main className="center-state"><p role="status">{error || "正在退出…"}</p>{error && <button className="secondary-button" onClick={() => void signOut()}>重试退出</button>}</main>;
  return <AppShell activeView={view} onNavigate={navigate} online={online} demo={demo} onSignOut={demo ? undefined : () => void signOut()}>
    {error && <div className="notice notice--red" role="alert"><span>{error}</span><button className="text-button" onClick={() => void refresh()}>重试</button></div>}
    {/* Keep the active question mounted when visiting another top-level page. */}
    <div hidden={view !== "today"}><TodayView key={bootstrap?.queueId ?? bootstrap?.learningDate ?? "loading"} active={view === "today"} client={client} bootstrap={bootstrap} dashboard={dashboard} loading={loading} demo={demo} online={online} onRefresh={refresh} onNavigate={navigate}/></div>
    {view === "intake" && <ContextView client={client}/>}
    <div hidden={view !== "analytics"}><AnalyticsView dashboard={dashboard} inventory={inventory.items} inventoryLoading={inventory.loading} inventoryError={inventory.error} loading={loading} onRefresh={refresh} onRecords={filter => { const query = new URLSearchParams(filter as Record<string, string>); location.hash = `history${query.size ? `?${query}` : ""}`; }}/></div>
    <div hidden={view !== "history"}><RecordsView active={view === "history"} query={recordsQuery} dataRevision={dataRevision} onQueryChanged={updateRecordsQuery} client={client} items={inventory.items} loading={inventory.loading} error={inventory.error} bootstrap={bootstrap} onToday={() => navigate("today")} onRefresh={refresh}/></div>
    {view === "library" && <LibraryWorkspace client={client} onGenerate={() => navigate("status")} onIntake={() => navigate("intake")}/>}
    {view === "status" && <SettingsView client={client} demo={demo} onSignOut={signOut} onChanged={refresh}/>}
  </AppShell>;
}
