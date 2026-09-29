import type { DiskUsage, Lookup } from "@/components/summary";
import type { TabId } from "@/components/vm-header";
import type { HostInfo } from "@/components/dashboard";
import type { HardwareSlots } from "@/lib/settings";
import type { Vm } from "@/lib/vm";

/** Slot limits used until `GET /api/capabilities` answers (they mirror `vm.zig`). */
export const DEFAULT_SLOTS: HardwareSlots = { nics: 8, extraDisks: 4 };

/** Guest IP and disk usage arrive after the summary is drawn; they are kept per VM so a redraw shows the last answer. */
export type VmLookups = {
  readonly id: string | null;
  readonly ip: Lookup<string>;
  readonly disk: Lookup<DiskUsage>;
};

export const LOADING_LOOKUPS: VmLookups = { id: null, ip: { kind: "loading" }, disk: { kind: "loading" } };

/**
 * The session: the VM list as the last poll left it and everything derived views depend on. The
 * background poll replaces `vms` wholesale, so any code that resolves a VM after an `await` must
 * look it up again by id (`indexOfId`) or name (`indexOfName`) instead of trusting an index.
 */
export type AppState = {
  vms: Array<Vm>;
  /** Index of the selected VM in `vms`, or null. */
  selected: number | null;
  activeTab: TabId;
  /** Index of the VM whose power change is in flight (its row is dimmed). */
  transitioning: number | null;
  selectMode: boolean;
  checkedIds: Set<string>;
  settingsDirty: boolean;
  serverDown: boolean;
  /** A settings save or reorder is running: the poll stands still so it cannot swap the list under it. */
  saveInFlight: boolean;
  refreshBusy: boolean;
  /** A daemon write is running; a second one is refused rather than queued. */
  postBusy: boolean;
  /** Bumped per write, so the safety timer only clears the write it was set for. */
  postGeneration: number;
  postPending: number;
  streamLive: boolean;
  /** A daemon write is running: the bar over the page slides. */
  loadBar: boolean;
  /** The console controllers have their host. */
  consoleReady: boolean;
  statusText: string;
  statusLoading: boolean;
  announcement: string;
  slots: HardwareSlots;
  host: HostInfo;
  /** The dashboard (or welcome state) is what the Summary panel shows. */
  dashboardShown: boolean;
  lookups: VmLookups;
  sidebarOpen: boolean;
  sidebarCollapsed: boolean;
};

export const state: AppState = {
  vms: [],
  selected: null,
  activeTab: "summary",
  transitioning: null,
  selectMode: false,
  checkedIds: new Set(),
  settingsDirty: false,
  serverDown: false,
  saveInFlight: false,
  refreshBusy: false,
  postBusy: false,
  postGeneration: 0,
  postPending: 0,
  streamLive: false,
  loadBar: false,
  consoleReady: false,
  statusText: "Ready",
  statusLoading: false,
  announcement: "",
  slots: DEFAULT_SLOTS,
  host: { cpuCores: 0, ramMib: 0 },
  dashboardShown: false,
  lookups: LOADING_LOOKUPS,
  sidebarOpen: false,
  sidebarCollapsed: false,
};

/** Current index of the VM with this stable id (it survives a rename), or -1. */
export const indexOfId = (id: string): number => (id === "" ? -1 : state.vms.findIndex((vm) => vm.id === id));

/** Current index of the VM with this name (unique on the daemon), or -1. */
export const indexOfName = (name: string): number => state.vms.findIndex((vm) => vm.name === name);

export const selectedVm = (): Vm | null => (state.selected === null ? null : (state.vms[state.selected] ?? null));

/** The selected VM, or null when the selection points past the list. */
export const vmAt = (index: number): Vm | null => state.vms[index] ?? null;
