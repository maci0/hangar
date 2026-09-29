import { LibraryActions } from "@/components/library-actions";
import { cn } from "@/lib/cn";
import {
  COLUMNS,
  dashStats,
  gauge,
  sortRows,
  type DashRow,
  type DashStats,
  type Gauge,
  type SortColumn,
  type SortState,
} from "@/lib/dashboard";
import { memGiB, memText, statusLabel, visibleTags } from "@/lib/format";
import { OsBadge, StatusDot, TagChip } from "@/components/vm-parts";

/** Physical capacity from `GET /api/host`; 0 while unknown. */
export type HostInfo = { readonly cpuCores: number; readonly ramMib: number };

export type DashboardProps = {
  readonly rows: ReadonlyArray<DashRow>;
  readonly host: HostInfo;
  readonly sort: SortState;
  readonly onSort: (col: SortColumn) => void;
};

type Tone = "running" | "paused" | "suspended";

const NUMBER_TONE: Readonly<Record<Tone, string>> = {
  running: "text-success",
  paused: "text-pause",
  suspended: "text-warn",
};

/** Stat tile. Read, not pressed: no hover or focus state. */
const Tile = ({ value, label, tone }: { readonly value: string; readonly label: string; readonly tone?: Tone }) => (
  <div class="dash-card rounded-md border border-border-soft bg-surface px-3.5 py-3 shadow-card">
    <div class={cn("dash-num text-2xl leading-none font-medium tracking-tight tabular-nums", tone === undefined ? "text-fg" : NUMBER_TONE[tone])}>
      {value}
    </div>
    <div class="mt-1.5 text-caption tracking-wider text-fg-dim uppercase">{label}</div>
  </div>
);

const GaugeRow = ({ label, gauge: g }: { readonly label: string; readonly gauge: Gauge }) => (
  <div class="cap-row my-1.75 grid grid-cols-gauge items-center gap-3 max-phone:grid-cols-2 max-phone:gap-y-1">
    <span class="text-field text-fg-muted">{label}</span>
    <div
      class="h-1.5 overflow-hidden rounded-full bg-inset max-phone:order-1 max-phone:col-span-2"
      aria-hidden="true"
    >
      <span
        class={cn("cap-fill block h-full rounded-full transition-all", g.over ? "bg-danger" : "bg-accent")}
        style={{ width: `${g.percent}%` }}
      />
    </div>
    <span class="cap-val justify-self-end text-field whitespace-nowrap text-fg tabular-nums">{g.label}</span>
    <span class="cap-over justify-self-end text-caption font-semibold whitespace-nowrap text-danger-text empty:hidden max-phone:order-2 max-phone:col-span-2 max-phone:justify-self-start">
      {g.overText}
    </span>
  </div>
);

const CapacityPanel = ({ host, vcpu, ramMib }: { readonly host: HostInfo; readonly vcpu: number; readonly ramMib: number }) => (
  <section class="cap-panel mb-4 max-w-190 rounded-md border border-border bg-surface px-4 py-3.5" aria-label="Host capacity">
    <div class="mb-2.5 flex items-baseline justify-between gap-3">
      <h3 class="text-xs font-semibold tracking-wide text-fg-dim uppercase">Host Capacity</h3>
      <span class="text-xs text-fg-muted">
        {host.cpuCores} cores · {memGiB(host.ramMib)} GiB RAM
      </span>
    </div>
    <GaugeRow label="vCPU committed" gauge={gauge(vcpu, host.cpuCores, "vCPU")} />
    <GaugeRow label="RAM committed" gauge={gauge(ramMib, host.ramMib, "MiB")} />
  </section>
);

const sortMark = (sort: SortState, col: SortColumn): string => {
  if (sort.col !== col) {
    return "";
  }
  return sort.dir === 1 ? " ▲" : " ▼";
};

const ariaSort = (sort: SortState, col: SortColumn): "ascending" | "descending" | "none" => {
  if (sort.col !== col) {
    return "none";
  }
  return sort.dir === 1 ? "ascending" : "descending";
};

const ROW_FOCUS = "focus-visible:outline-2 -outline-offset-2 focus-visible:outline-accent";

const SortHeader = ({ col, label, sort, onSort }: { readonly col: SortColumn; readonly label: string } & Pick<DashboardProps, "sort" | "onSort">) => (
  <th
    class={cn(
      "cursor-pointer border-b border-border bg-bg-alt px-3 py-1.5 text-left text-caption font-bold tracking-wider whitespace-nowrap text-fg-dim uppercase select-none hover:text-fg",
      ROW_FOCUS,
    )}
    data-action="sortInv"
    data-col={col}
    tabIndex={0}
    aria-sort={ariaSort(sort, col)}
    onClick={() => onSort(col)}
    onKeyDown={(event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onSort(col);
      }
    }}
  >
    {label}
    <span aria-hidden="true">{sortMark(sort, col)}</span>
  </th>
);

const CELL = "px-3 py-1.25 align-middle whitespace-nowrap";

const InventoryRow = ({ index, vm, brand }: DashRow) => (
  <tr
    class={cn("cursor-pointer border-t border-border-soft transition-colors first:border-t-0 hover:bg-accent-soft", ROW_FOCUS)}
    data-action="select"
    data-vm-index={index}
    tabIndex={0}
  >
    <td class={cn(CELL, "inv-name font-semibold text-fg")}>{vm.name}</td>
    <td class={cn(CELL, "text-fg")}>
      <StatusDot status={vm.status} />
      {statusLabel(vm.status)}
    </td>
    <td class={cn(CELL, "text-fg")}>
      <span class="inline-flex items-center gap-2">
        <OsBadge brand={brand} />
        {vm.os}
      </span>
    </td>
    <td class={cn(CELL, "text-fg tabular-nums")}>{vm.cpu}</td>
    <td class={cn(CELL, "text-fg tabular-nums")}>{memText(vm.mem)}</td>
    <td class={cn(CELL, "text-fg tabular-nums")}>{vm.disk} GB</td>
    <td class={cn(CELL, "text-fg-dim")}>{vm.folder}</td>
    <td class={CELL}>
      {visibleTags(vm.tags).map((tag) => (
        <TagChip key={tag}>{tag}</TagChip>
      ))}
    </td>
  </tr>
);

const Inventory = ({ rows, sort, onSort }: Pick<DashboardProps, "rows" | "sort" | "onSort">) => (
  <div class="inv-wrap mt-3 overflow-x-auto rounded-md border border-border-soft bg-surface shadow-card">
    <table class="inv w-full border-collapse text-field">
      <thead>
        <tr>
          {COLUMNS.map(({ col, label }) => (
            <SortHeader key={col} col={col} label={label} sort={sort} onSort={onSort} />
          ))}
        </tr>
      </thead>
      <tbody>
        {sortRows(rows, sort).map((row) => (
          <InventoryRow key={row.vm.id} {...row} />
        ))}
      </tbody>
    </table>
  </div>
);

const StateTiles = ({ stats }: { readonly stats: DashStats }) => (
  <>
    <div class="mb-3 grid grid-cols-tiles gap-3">
      <Tile value={String(stats.running)} label="Running" tone="running" />
      <Tile value={String(stats.stopped)} label="Stopped" />
      <Tile value={String(stats.paused)} label="Paused" tone="paused" />
      <Tile value={String(stats.suspended)} label="Suspended" tone="suspended" />
    </div>
    <div class="mb-3 grid grid-cols-tiles gap-3">
      <Tile value={String(stats.vcpu)} label="vCPU allocated" />
      <Tile value={`${memGiB(stats.ramMib)} GiB`} label="RAM allocated" />
      <Tile value={`${stats.diskGb} GB`} label="Disk provisioned" />
    </div>
  </>
);

const Attention = ({ names }: { readonly names: ReadonlyArray<string> }) => (
  <section class="dash-attention mb-3 rounded-md border border-l-3 border-border-soft border-l-warn bg-surface px-3.5 py-2.5 shadow-card">
    <h3 class="mb-1.5 text-caption font-bold tracking-wider text-warn uppercase">Needs attention</h3>
    <ul class="m-0 pl-4">
      {names.map((name) => (
        <li key={name} class="py-px text-field text-fg-muted">
          {name}
        </li>
      ))}
    </ul>
  </section>
);

/** Host inventory shown while no VM is selected: capacity, state counts, allocation, attention list, sortable table. */
export const Dashboard = ({ rows, host, sort, onSort }: DashboardProps) => {
  const stats = dashStats(rows.map((row) => row.vm));
  const count = rows.length;
  return (
    <div class="dash max-w-275">
      <div class="dash-head mb-3 flex items-baseline gap-2.5">
        <h3 class="text-heading font-semibold tracking-tight">Inventory</h3>
        <span class="text-xs text-fg-dim">
          {count} virtual machine{count === 1 ? "" : "s"}
        </span>
      </div>
      {(host.cpuCores > 0 || host.ramMib > 0) && <CapacityPanel host={host} vcpu={stats.vcpu} ramMib={stats.ramMib} />}
      <StateTiles stats={stats} />
      {stats.attention.length > 0 && <Attention names={stats.attention} />}
      <Inventory rows={rows} sort={sort} onSort={onSort} />
      <div class="mt-4.5 flex flex-wrap gap-2">
        <LibraryActions />
      </div>
    </div>
  );
};
