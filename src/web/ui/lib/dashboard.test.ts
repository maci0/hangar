import { describe, expect, test } from "bun:test";
import { dashStats, DEFAULT_SORT, gauge, nextSort, sortRows, type DashRow } from "@/lib/dashboard";
import { sampleVm } from "@/lib/vm-fixture";
import type { Vm } from "@/lib/vm";

const BRAND = { color: "var(--accent)", text: "L" };
const row = (index: number, overrides: Partial<Vm>): DashRow => ({ index, vm: sampleVm(overrides), brand: BRAND });

describe("dashStats", () => {
  test("counts states and sums the allocation in exact units", () => {
    const stats = dashStats([
      sampleVm({ status: "running", cpu: 2, mem: 1536, disk: 10 }),
      sampleVm({ status: "stopped", cpu: 4, mem: 512, disk: 30 }),
      sampleVm({ status: "paused", cpu: 1, mem: 1, disk: 0 }),
    ]);
    expect(stats).toMatchObject({ running: 1, stopped: 1, paused: 1, suspended: 0, vcpu: 7, ramMib: 2049, diskGb: 40 });
  });

  test("lists the VMs that have a warning", () => {
    const stats = dashStats([sampleVm({ name: "ok" }), sampleVm({ name: "offline", net: "none" })]);
    expect(stats.attention).toEqual(["offline"]);
  });

  test("is all zero for an empty inventory", () => {
    expect(dashStats([])).toEqual({ running: 0, stopped: 0, paused: 0, suspended: 0, vcpu: 0, ramMib: 0, diskGb: 0, attention: [] });
  });
});

describe("sorting", () => {
  const rows = [row(0, { name: "beta", mem: 1024 }), row(1, { name: "Alpha", mem: 4096 }), row(2, { name: "gamma", mem: 512 })];

  test("orders text case-insensitively and reverses on demand", () => {
    expect(sortRows(rows, DEFAULT_SORT).map((r) => r.vm.name)).toEqual(["Alpha", "beta", "gamma"]);
    expect(sortRows(rows, { col: "name", dir: -1 }).map((r) => r.vm.name)).toEqual(["gamma", "beta", "Alpha"]);
  });

  test("orders numbers by value, not text", () => {
    expect(sortRows(rows, { col: "mem", dir: 1 }).map((r) => r.vm.mem)).toEqual([512, 1024, 4096]);
  });

  test("keeps the list index of every row", () => {
    expect(sortRows(rows, DEFAULT_SORT).map((r) => r.index)).toEqual([1, 0, 2]);
  });

  test("clicking the sorted column flips it, another starts ascending", () => {
    expect(nextSort(DEFAULT_SORT, "name")).toEqual({ col: "name", dir: -1 });
    expect(nextSort({ col: "name", dir: -1 }, "name")).toEqual({ col: "name", dir: 1 });
    expect(nextSort({ col: "name", dir: -1 }, "cpu")).toEqual({ col: "cpu", dir: 1 });
  });
});

describe("gauge", () => {
  test("shows committed against physical", () => {
    expect(gauge(2048, 8192, "MiB")).toEqual({ percent: 25, over: false, label: "2048 / 8192 MiB", overText: "" });
  });

  test("flags overcommit from exact quantities, one MiB over is over", () => {
    const one = gauge(4097, 4096, "MiB");
    expect(one.over).toBe(true);
    expect(one.percent).toBe(100);
    expect(one.overText).toBe("1× overcommit");
    expect(gauge(4096, 4096, "MiB").over).toBe(false);
    expect(gauge(6144, 4096, "MiB").overText).toBe("1.5× overcommit");
  });

  test("an unknown host has no ratio", () => {
    expect(gauge(512, 0, "MiB")).toEqual({ percent: 0, over: false, label: "512 MiB", overText: "" });
  });
});
