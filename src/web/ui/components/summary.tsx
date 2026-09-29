import type { ComponentChildren } from "preact";
import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { TagChip } from "@/components/vm-parts";
import { cn } from "@/lib/cn";
import { fmtBytes, memText, percentOf, statusLabel, visibleTags } from "@/lib/format";
import { networkLabel, videoSummary, vmWarnings, type Vm, type VmStatus } from "@/lib/vm";
import type { HardwareSlots } from "@/lib/settings";

/** A value fetched after the summary is drawn: guest IP, disk usage. */
export type Lookup<T> =
  | { readonly kind: "loading" }
  | { readonly kind: "ready"; readonly value: T }
  | { readonly kind: "unavailable"; readonly text: string };

export type DiskUsage = { readonly actualBytes: number; readonly virtualBytes: number };

export type SummaryProps = {
  readonly vm: Vm;
  /** The VM's folder path, empty when it has none. */
  readonly folder: string;
  readonly guestIp: Lookup<string>;
  readonly diskUsage: Lookup<DiskUsage>;
  readonly slots: HardwareSlots;
};

const BADGE_TONE: Readonly<Record<VmStatus, string>> = {
  running: "border-success/55 bg-success/8 text-success",
  paused: "border-pause/55 bg-pause/8 text-pause",
  suspended: "border-warn/55 bg-warn/8 text-warn",
  stopped: "border-border bg-surface text-fg-dim",
};

const FACT = "rounded-sm border border-border-soft bg-surface px-2.25 py-0.75 text-xs text-fg-muted";

const lookupText = <T,>(lookup: Lookup<T>, ready: (value: T) => string): string => {
  if (lookup.kind === "loading") {
    return "…";
  }
  return lookup.kind === "ready" ? ready(lookup.value) : lookup.text;
};

const DiskUsageBar = ({ usage }: { readonly usage: Lookup<DiskUsage> }) => {
  if (usage.kind !== "ready") {
    return (
      <div id="diskUsageVal" class="usage mt-1.25 text-caption font-normal text-fg-dim">
        {lookupText(usage, () => "")}
      </div>
    );
  }
  const { actualBytes, virtualBytes } = usage.value;
  const percent = percentOf(actualBytes, virtualBytes);
  return (
    <div id="diskUsageVal" class="usage mt-1.25">
      <div class="h-1 overflow-hidden rounded-xs bg-border-soft">
        <span class="block h-full bg-accent transition-all" style={{ width: `${percent}%` }} />
      </div>
      <div class="mt-0.75 text-caption font-normal text-fg-dim">
        {fmtBytes(actualBytes)} used / {fmtBytes(virtualBytes)} ({percent}%)
      </div>
    </div>
  );
};

type Row = { readonly label: string; readonly icon?: string; readonly value: ComponentChildren };

const Rows = ({ rows }: { readonly rows: ReadonlyArray<Row> }) => (
  <dl class="m-0 flex flex-col">
    {rows.map(({ label, icon, value }) => (
      <div key={label} class="srow flex items-start justify-between gap-3.5 border-t border-border-soft py-1.25 first:border-t-0">
        <dt class="inline-flex flex-none items-center gap-1.75 text-field text-fg-muted">
          {icon !== undefined && <Icon name={icon} class="size-3.5 flex-none text-fg-dim" />}
          {label}
        </dt>
        <dd class="m-0 max-w-2/3 text-right text-field font-medium wrap-anywhere text-fg tabular-nums">{value}</dd>
      </div>
    ))}
  </dl>
);

const Section = ({ title, wide, children }: { readonly title: string; readonly wide?: true; readonly children: ComponentChildren }) => (
  <section class={cn("rounded-md border border-border-soft bg-surface px-4 py-3 shadow-card", wide && "col-span-full")}>
    <h3 class="mb-1 text-caption font-bold tracking-wider text-fg-dim uppercase">{title}</h3>
    {children}
  </section>
);

const extraDisks = (vm: Vm, count: number): ReadonlyArray<Row> => {
  const rows: Array<Row> = [];
  for (let n = 0; n < count; n += 1) {
    if (vm[`extra${n}_path`] !== undefined && vm[`extra${n}_path`] !== "") {
      rows.push({ label: `Extra Disk ${n + 1}`, value: `${vm[`extra${n}_size`] ?? 0} GB` });
    }
  }
  return rows;
};

const extraNics = (vm: Vm, count: number): ReadonlyArray<Row> => {
  const rows: Array<Row> = [];
  for (let n = 2; n <= count; n += 1) {
    const mode = vm[`nic${n}_mode`];
    if (mode !== undefined && mode !== "" && mode !== "none") {
      rows.push({ label: `NIC ${n}`, value: mode });
    }
  }
  return rows;
};

const hardwareRows = ({ vm, diskUsage, slots }: SummaryProps): ReadonlyArray<Row> => [
  {
    label: "CPU",
    icon: "cpu",
    value: `${vm.cpu} ${vm.cpu === 1 ? "core" : "cores"}${vm.cpu_sockets > 1 ? ` · ${vm.cpu_sockets} sockets` : ""}`,
  },
  { label: "Memory", icon: "ram", value: memText(vm.mem) },
  {
    label: "Hard Disk",
    icon: "hdd",
    value: (
      <>
        {vm.disk} GB
        {vm.hasDisk === "true" && <DiskUsageBar usage={diskUsage} />}
      </>
    ),
  },
  ...(vm.hasDisk2 === "true" ? [{ label: "Disk 2", value: `${vm.disk2_size} GB` }] : []),
  ...extraDisks(vm, slots.extraDisks),
  ...(vm.iso_path === "" ? [] : [{ label: "CD/DVD", value: vm.iso_path }]),
  ...(vm.hasFloppy === "true" ? [{ label: "Floppy", value: "attached" }] : []),
  { label: "Network", icon: "net", value: `${networkLabel(vm)}${vm.mac === "" ? "" : ` · ${vm.mac}`}` },
  ...(vm.vnet === "" ? [] : [{ label: "Virtual Network", value: vm.vnet }]),
  ...extraNics(vm, slots.nics),
  { label: "Video", icon: "monitor", value: videoSummary(vm) },
  ...(vm.usb_device === "" ? [] : [{ label: "USB Device", value: vm.usb_device }]),
];

const guestRows = (vm: Vm): ReadonlyArray<Row> => [
  { label: "Guest OS", value: vm.os },
  {
    label: "Guest Tools",
    value:
      vm.guest_tools === "true" ? (
        <span class="inline-flex items-center gap-1 font-semibold text-success">
          <Icon name="check" class="size-3" />
          installed
        </span>
      ) : (
        <span class="font-normal text-fg-dim">not installed</span>
      ),
  },
  ...(vm.autoprotect === "true"
    ? [{ label: "AutoProtect", value: `every ${vm.autoprotect_interval} min · keep ${vm.autoprotect_max}` }]
    : []),
];

const optionRows = (vm: Vm): ReadonlyArray<Row> => [
  ...(vm.shared_folder === "" ? [] : [{ label: "Shared Folder", value: vm.shared_folder }]),
  ...(vm.port_forwards === "" ? [] : [{ label: "Port Forwards", value: vm.port_forwards }]),
];

const Warnings = ({ warnings }: { readonly warnings: ReadonlyArray<string> }) => (
  <div class="mt-3.5 rounded-md border border-l-3 border-border-soft border-l-warn bg-surface px-3.5 py-2.5">
    <div class="mb-1 text-caption font-bold tracking-wider text-fg-dim uppercase">Attention</div>
    <div class="grid gap-1 text-field font-semibold text-fg-muted">
      {warnings.map((warning) => (
        <div key={warning}>{warning}</div>
      ))}
    </div>
  </div>
);

const Facts = ({ vm, guestIp }: Pick<SummaryProps, "vm" | "guestIp">) => (
  <div class="vm-facts mb-4 flex flex-wrap items-center gap-1.5">
    <span class={cn("rounded-sm border px-2.25 py-0.75 text-caption font-bold tracking-wider uppercase", BADGE_TONE[vm.status])}>
      {statusLabel(vm.status)}
    </span>
    <span class={FACT}>{vm.os}</span>
    <span class={FACT}>
      <b class="font-semibold text-fg">{vm.cpu}</b> vCPU
    </span>
    <span class={FACT}>
      <b class="font-semibold text-fg">{memText(vm.mem)}</b> RAM
    </span>
    <span class={FACT}>
      <b class="font-semibold text-fg">{vm.disk}</b> GB disk
    </span>
    {vm.status === "running" && (
      <span class={FACT}>
        IP <span id="guestIpVal">{lookupText(guestIp, (ips) => ips)}</span>
      </span>
    )}
  </div>
);

const Cards = ({ vm, folder, hardware }: { readonly vm: Vm; readonly folder: string; readonly hardware: ReadonlyArray<Row> }) => {
  const options = optionRows(vm);
  const tags = visibleTags(vm.tags);
  return (
    <div class="grid grid-cols-summary items-start gap-3">
      <Section title="VM Hardware">
        <Rows rows={hardware} />
      </Section>
      <Section title="Guest & Tools">
        <Rows rows={guestRows(vm)} />
      </Section>
      {options.length > 0 && (
        <Section title="Options">
          <Rows rows={options} />
        </Section>
      )}
      {tags.length > 0 && (
        <Section title="Tags">
          <div class="flex flex-wrap gap-1">
            {tags.map((tag) => (
              <TagChip key={tag}>{tag}</TagChip>
            ))}
          </div>
        </Section>
      )}
      {folder !== "" && (
        <Section title="Folder">
          <Rows rows={[{ label: "Path", value: folder }]} />
        </Section>
      )}
      {vm.notes !== "" && (
        <Section title="Notes" wide>
          <div class="text-field leading-relaxed whitespace-pre-wrap text-fg-muted">{vm.notes}</div>
        </Section>
      )}
    </div>
  );
};

/** Summary tab of the selected VM: state and size chips, hardware, guest, options, tags, notes. */
export const Summary = (props: SummaryProps) => {
  const { vm, folder, guestIp } = props;
  const warnings = vmWarnings(vm);
  return (
    <>
      <Facts vm={vm} guestIp={guestIp} />
      <Cards vm={vm} folder={folder} hardware={hardwareRows(props)} />
      {warnings.length > 0 && <Warnings warnings={warnings} />}
      <div class="mt-4 flex gap-2">
        <Button data-action="viewLog">View QEMU Log</Button>
        {vm.status === "running" && <Button data-action="takeScreenshot">Screenshot</Button>}
      </div>
    </>
  );
};
