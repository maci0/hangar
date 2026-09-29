import { percentOf } from "@/lib/format";
import { vmWarnings, type OsBrand, type Vm } from "@/lib/vm";

/** One inventory row: the VM, its position in the daemon's list (the id the actions address) and its emblem. */
export type DashRow = {
  readonly index: number;
  readonly vm: Vm;
  readonly brand: OsBrand;
};

export type DashStats = {
  readonly running: number;
  readonly stopped: number;
  readonly paused: number;
  readonly suspended: number;
  readonly vcpu: number;
  /** Exact MiB; round only for display. */
  readonly ramMib: number;
  readonly diskGb: number;
  /** Names of the VMs with a configuration warning. */
  readonly attention: ReadonlyArray<string>;
};

const finite = (quantity: number): number => (Number.isFinite(quantity) ? quantity : 0);

export const dashStats = (vms: ReadonlyArray<Vm>): DashStats => {
  const counts = { running: 0, stopped: 0, paused: 0, suspended: 0 };
  let vcpu = 0;
  let ramMib = 0;
  let diskGb = 0;
  const attention: Array<string> = [];
  for (const vm of vms) {
    counts[vm.status] += 1;
    vcpu += finite(vm.cpu);
    ramMib += finite(vm.mem);
    diskGb += finite(vm.disk);
    if (vmWarnings(vm).length > 0) {
      attention.push(vm.name);
    }
  }
  return { ...counts, vcpu, ramMib, diskGb, attention };
};

export type SortColumn = "name" | "status" | "os" | "cpu" | "mem" | "disk" | "folder" | "tags";

export type SortState = { readonly col: SortColumn; readonly dir: 1 | -1 };

export const COLUMNS: ReadonlyArray<{ readonly col: SortColumn; readonly label: string }> = [
  { col: "name", label: "Name" },
  { col: "status", label: "State" },
  { col: "os", label: "Guest OS" },
  { col: "cpu", label: "vCPU" },
  { col: "mem", label: "RAM" },
  { col: "disk", label: "Disk" },
  { col: "folder", label: "Folder" },
  { col: "tags", label: "Tags" },
];

export const DEFAULT_SORT: SortState = { col: "name", dir: 1 };

/** Clicking the sorted column reverses it; another column starts ascending. */
export const nextSort = (current: SortState, col: SortColumn): SortState =>
  current.col === col ? { col, dir: current.dir === 1 ? -1 : 1 } : { col, dir: 1 };

type NumericColumn = "cpu" | "mem" | "disk";

const isNumeric = (col: SortColumn): col is NumericColumn => col === "cpu" || col === "mem" || col === "disk";

/** Rows ordered by the column: numbers by value, text case-insensitively; ties keep list order. */
export const sortRows = (rows: ReadonlyArray<DashRow>, { col, dir }: SortState): ReadonlyArray<DashRow> => {
  if (isNumeric(col)) {
    return rows.toSorted((left, right) => (finite(left.vm[col]) - finite(right.vm[col])) * dir);
  }
  return rows.toSorted((left, right) => {
    const a = left.vm[col].toLowerCase();
    const b = right.vm[col].toLowerCase();
    if (a < b) {
      return -dir;
    }
    return a > b ? dir : 0;
  });
};

/** Committed capacity against the host's; the bar fills to `percent` and turns red past 100% of the host. */
export type Gauge = {
  readonly percent: number;
  readonly over: boolean;
  readonly label: string;
  /** `1.5× overcommit`, or empty when within capacity. */
  readonly overText: string;
};

const RATIO_DECIMALS = 100;

/** `physical` of 0 means the host size is unknown: no ratio, no overcommit. */
export const gauge = (committed: number, physical: number, unit: string): Gauge => {
  const known = physical > 0;
  const over = known && committed > physical;
  return {
    percent: percentOf(committed, physical),
    over,
    label: known ? `${committed} / ${physical} ${unit}` : `${committed} ${unit}`,
    overText: over ? `${Math.round((committed / physical) * RATIO_DECIMALS) / RATIO_DECIMALS}× overcommit` : "",
  };
};
