import { describe, expect, test } from "bun:test";
import { buildVmList, inventorySummary, parseVmList, uptimeText, type ListModel } from "@/lib/inventory";
import { sampleVm } from "@/lib/vm-fixture";

const model = (overrides: Partial<ListModel>): ListModel => ({
  vms: [],
  selected: null,
  transitioning: null,
  checked: new Set(),
  selectMode: false,
  filter: "",
  folderOpen: () => true,
  ...overrides,
});

describe("parseVmList", () => {
  test("turns JSON booleans into the strings the UI compares", () => {
    const parsed = parseVmList([{ id: "a", name: "web", status: "stopped", favorite: true, hasDisk: false, mem: 512 }]);
    expect(parsed?.[0]).toMatchObject({ favorite: "true", hasDisk: "false", mem: 512 });
  });

  test("rejects anything that is not a list of VM records", () => {
    expect(parseVmList({ error: "x" })).toBeNull();
    expect(parseVmList([1])).toBeNull();
    expect(parseVmList([{ id: "a", name: "web", status: "exploding" }])).toBeNull();
    expect(parseVmList([{ name: "web", status: "stopped" }])).toBeNull();
    expect(parseVmList([])).toEqual([]);
  });
});

describe("buildVmList", () => {
  const web = sampleVm({ id: "1", name: "web", tags: "prod", cpu: 2, mem: 2048 });
  const db = sampleVm({ id: "2", name: "db", favorite: "true", folder: "core" });
  const lab = sampleVm({ id: "3", name: "lab", folder: "Zed" });
  const vms = [web, db, lab];

  test("favorites first, then sorted folders, then ungrouped", () => {
    const list = buildVmList(model({ vms }));
    expect(list.favorites.map((row) => row.name)).toEqual(["db"]);
    expect(list.folders.map((folder) => folder.name)).toEqual(["Zed"]);
    expect(list.ungrouped.map((row) => row.name)).toEqual(["web"]);
    expect(list.ungrouped[0]?.meta).toBe("2 vCPU · 2 GiB");
    expect(list.ungrouped[0]?.index).toBe(0);
  });

  test("the search matches name and tags case-insensitively", () => {
    expect(buildVmList(model({ vms, filter: "PROD" })).ungrouped.map((row) => row.name)).toEqual(["web"]);
    const none = buildVmList(model({ vms, filter: "zzz" }));
    expect(none.filtered).toBe(true);
    expect(none.favorites).toHaveLength(0);
  });

  test("one tab stop: the selected row, else the first visible row", () => {
    const rows = (selected: number | null) => {
      const list = buildVmList(model({ vms, selected }));
      return [...list.favorites, ...list.folders.flatMap((folder) => folder.rows), ...list.ungrouped].filter((row) => row.tabStop).map((row) => row.name);
    };
    expect(rows(null)).toEqual(["web"]);
    expect(rows(2)).toEqual(["lab"]);
  });

  test("marks the active, transitioning and checked rows", () => {
    const list = buildVmList(model({ vms, selected: 0, transitioning: 0, checked: new Set(["1"]) }));
    expect(list.ungrouped[0]).toMatchObject({ active: true, transitioning: true, checked: true });
  });
});

describe("inventorySummary and uptimeText", () => {
  test("counts VMs and states", () => {
    const vms = [sampleVm({ status: "running" }), sampleVm({ status: "paused" }), sampleVm()];
    expect(inventorySummary(vms, null)).toBe("3 virtual machines, 1 running, 1 paused");
    expect(inventorySummary([sampleVm()], null)).toBe("1 virtual machine");
  });

  test("a running selection shows the daemon uptime, zero included", () => {
    const running = sampleVm({ name: "web", status: "running", uptime_sec: 90_061 });
    expect(inventorySummary([running], running)).toBe("web: running | Uptime: 1d 1:01:01    |    1 virtual machine, 1 running");
    const fresh = sampleVm({ name: "web", status: "running", uptime_sec: 0 });
    expect(inventorySummary([fresh], fresh)).toContain("Uptime: 0:00:00");
  });

  test("unusable uptimes are omitted", () => {
    for (const uptime of [-1, Number.NaN, undefined]) {
      const vm = sampleVm({ name: "web", status: "running", uptime_sec: uptime });
      expect(inventorySummary([vm], vm)).not.toContain("Uptime");
    }
    const stopped = sampleVm({ name: "web", uptime_sec: 5 });
    expect(inventorySummary([stopped], stopped)).not.toContain("Uptime");
  });

  test("uptimeText pads minutes and seconds", () => {
    expect(uptimeText(59)).toBe("0:00:59");
    expect(uptimeText(3661)).toBe("1:01:01");
  });
});
