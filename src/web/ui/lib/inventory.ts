import type { VmFolder, VmListProps, VmRow } from "@/components/vm-list";
import { memText } from "@/lib/format";
import { vmFolder } from "@/lib/folders";
import type { Vm, VmStatus } from "@/lib/vm";
import { listOf } from "@/lib/wire";

const STATUSES: ReadonlySet<string> = new Set(["running", "paused", "suspended", "stopped"]);

const isVm = (record: Readonly<Record<string, unknown>>): record is Vm =>
  typeof record.id === "string" && typeof record.name === "string" && typeof record.status === "string" && STATUSES.has(record.status);

/**
 * Reads `GET /api/vms`. The daemon encodes config flags as JSON booleans while the UI compares the
 * strings `"true"` and `"false"`, so every boolean field is turned into its string. Returns null
 * when the body is not a list of VM records.
 */
export const parseVmList = (body: unknown): Array<Vm> | null => {
  const records = listOf(body);
  if (records === null) {
    return null;
  }
  const vms: Array<Vm> = [];
  for (const record of records) {
    if (typeof record !== "object" || record === null) {
      return null;
    }
    const flagged = Object.fromEntries(Object.entries(record).map(([field, setting]) => [field, typeof setting === "boolean" ? String(setting) : setting]));
    if (!isVm(flagged)) {
      return null;
    }
    vms.push(flagged);
  }
  return vms;
};

/** What the sidebar list is drawn from. */
export type ListModel = {
  readonly vms: ReadonlyArray<Vm>;
  readonly selected: number | null;
  readonly transitioning: number | null;
  readonly checked: ReadonlySet<string>;
  readonly selectMode: boolean;
  /** Search text; the match is case-insensitive over name and tags. */
  readonly filter: string;
  readonly folderOpen: (name: string) => boolean;
};

const rowStatus = (status: string): VmStatus => (status === "running" || status === "paused" || status === "suspended" ? status : "stopped");

const matches = (vm: Vm, needle: string): boolean => needle === "" || vm.name.toLowerCase().includes(needle) || vm.tags.toLowerCase().includes(needle);

/** Sidebar rows: favorites first, then collapsible folders (sorted), then ungrouped VMs. */
export const buildVmList = (model: ListModel): Omit<VmListProps, "handlers"> => {
  const needle = model.filter.toLowerCase();
  const visible = model.vms.map((vm, index) => ({ vm, index, show: matches(vm, needle) })).filter((entry) => entry.show);
  // The list is one tab stop: the selected row, or the first visible row while nothing is selected.
  const tabStop = model.selected ?? visible[0]?.index ?? -1;
  const rowOf = ({ vm, index }: (typeof visible)[number]): VmRow => ({
    index,
    id: vm.id,
    name: vm.name,
    status: rowStatus(vm.status),
    meta: `${vm.cpu || 1} vCPU · ${memText(vm.mem)}`,
    favorite: vm.favorite === "true",
    active: model.selected === index,
    transitioning: model.transitioning === index,
    checked: model.checked.has(vm.id),
    tabStop: index === tabStop,
  });
  const folders = new Map<string, Array<VmRow>>();
  const ungrouped: Array<VmRow> = [];
  for (const entry of visible) {
    if (entry.vm.favorite !== "true") {
      const folder = vmFolder(entry.vm);
      if (folder === "") {
        ungrouped.push(rowOf(entry));
      } else {
        folders.set(folder, [...(folders.get(folder) ?? []), rowOf(entry)]);
      }
    }
  }
  const sorted: Array<VmFolder> = [...folders.keys()]
    .toSorted()
    .map((name) => ({ name, open: model.folderOpen(name), rows: folders.get(name) ?? [] }));
  return {
    favorites: visible.filter((entry) => entry.vm.favorite === "true").map((entry) => rowOf(entry)),
    folders: sorted,
    ungrouped,
    selectMode: model.selectMode,
    filtered: needle !== "",
  };
};

const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86_400;
const CLOCK_DIGITS = 2;

/** `1d 1:01:01` from the daemon's elapsed seconds; the days part is left out under a day. */
export const uptimeText = (seconds: number): string => {
  const elapsed = Math.floor(seconds);
  const days = Math.floor(elapsed / SECONDS_PER_DAY);
  const hours = Math.floor((elapsed % SECONDS_PER_DAY) / SECONDS_PER_HOUR);
  const minutes = Math.floor((elapsed % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE);
  const rest = elapsed % SECONDS_PER_MINUTE;
  const clock = `${hours}:${String(minutes).padStart(CLOCK_DIGITS, "0")}:${String(rest).padStart(CLOCK_DIGITS, "0")}`;
  return days > 0 ? `${days}d ${clock}` : clock;
};

const plural = (count: number, noun: string): string => `${count} ${noun}${count === 1 ? "" : "s"}`;

/** Passive status line: `3 virtual machines, 1 running`, with the selected VM in front when there is one. */
export const inventorySummary = (vms: ReadonlyArray<Vm>, selected: Vm | null): string => {
  const count = (status: VmStatus): number => vms.filter((vm) => vm.status === status).length;
  let parts = plural(vms.length, "virtual machine");
  for (const status of ["running", "paused", "suspended"] as const) {
    if (count(status) > 0) {
      parts += `, ${count(status)} ${status}`;
    }
  }
  if (selected === null) {
    return parts;
  }
  const uptime = selected.status === "running" && typeof selected.uptime_sec === "number" && Number.isFinite(selected.uptime_sec) && selected.uptime_sec >= 0;
  const head = `${selected.name}: ${selected.status}`;
  return `${uptime ? `${head} | Uptime: ${uptimeText(selected.uptime_sec ?? 0)}` : head}    |    ${parts}`;
};
