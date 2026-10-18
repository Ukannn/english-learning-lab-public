import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AnalyticsView } from "./AnalyticsView";
import type { DashboardData } from "../lib/contracts";

afterEach(cleanup);
describe("learning report time coverage", () => {
  it("keeps undated historical reading separate from dated study time", () => {
    const dashboard: DashboardData = {
      ok: true, learningDate: "2026-10-18", today: { planned: 1, completed: 1, waitingForGrading: 0 },
      totals: { phrases: 1, reviews: 1, accuracy: 100 },
      v3: { completedLessons: 1, dueCount: 0, burden: [], unallocatedReadingSeconds: 90,
        days: [{ date: "2026-10-18", durationMinutes: 2, independentAttempts: 1, independentSuccess: 1,
          attempts: 1, hinted: 0, gapAttempts: 0, gapSuccess: 0, expressionAttempts: 0, expressionSuccess: 0,
          unmeasured: 0, delayedAttempts: 0, delayedSuccess: 0 }] },
    };
    const view = render(<AnalyticsView dashboard={dashboard} inventory={[]} loading={false} onRefresh={vi.fn(async () => undefined)} onRecords={vi.fn()}/>);
    expect(screen.getByText(/已记录 2 分钟/).textContent).toContain("上海学习日期");
    expect(screen.getByText(/累计 1.5 分钟阅读缺少日期记录/).textContent).toContain("不计入每日用时");
    fireEvent.click(screen.getByRole("button", { name: "查看每日数字" }));
    expect(screen.getByRole("cell", { name: "2 分钟" })).toBeTruthy();
    expect(screen.queryByRole("cell", { name: "3.5 分钟" })).toBeNull();
    dashboard.v3!.completedLessons = 0;
    dashboard.v3!.days[0].attempts = 0;
    dashboard.v3!.days[0].independentAttempts = 0;
    dashboard.v3!.days[0].independentSuccess = 0;
    view.rerender(<AnalyticsView dashboard={dashboard} inventory={[]} loading={false} onRefresh={vi.fn(async () => undefined)} onRecords={vi.fn()}/>);
    expect(screen.getByText(/1 个活跃日期，已记录 2 分钟/)).toBeTruthy();
    expect(screen.getByText("独立提取 · 0/0 次")).toBeTruthy();
  });
});
