import { consoleHost, sendCad } from "@/app/console-host";
import { searchText, setStatusText, syncShell } from "@/app/feedback";
import { indexOfId, LOADING_LOOKUPS, selectedVm, state } from "@/app/state";
import { ui } from "@/bridge";
import type { DiskUsage, Lookup } from "@/components/summary";
import type { SummaryView } from "@/panels";
import { actionReason, type VmAction } from "@/lib/actions";
import { AUTH_HEADERS } from "@/lib/api";
import { folderOpen, vmFolder } from "@/lib/folders";
import { buildVmList, inventorySummary } from "@/lib/inventory";
import { osBrand } from "@/lib/os-brand";
import { embeddedDisplayCapable, type Vm } from "@/lib/vm";
import { parseDiskInfo, parseGuestIps, parseHost } from "@/lib/wire";

const PAGE_TITLE = "Hangar: ";
const EMPTY_TITLE = "Hangar, VM Manager";

/** Why `action` is off for the selected VM, or null; the toolbar and the console buttons share it. */
export const reasonFor = (action: VmAction): string | null => actionReason(action, selectedVm(), state.vms);

// ── Toolbar and console ──────────────────────────────────────────────

export const syncToolbar = (): void => {
  const vm = selectedVm();
  ui.setToolbar({ hasVm: vm !== null, powered: vm?.status === "running" || vm?.status === "paused", actionReason: reasonFor });
};

/** Hands the console its host once, then the selected VM and the button reasons on every change. */
export const syncConsole = (): void => {
  if (!state.consoleReady) {
    state.consoleReady = true;
    ui.initConsole(consoleHost);
  }
  ui.setConsole({ vm: selectedVm(), actionReason: reasonFor, sendCad: () => void sendCad() });
};

/** Everything that depends on the selection or the VM's state. */
export const updateCommandState = (): void => {
  syncToolbar();
  syncShell();
  syncConsole();
};

// ── Sidebar list ─────────────────────────────────────────────────────

/** Drops checked ids of VMs deleted or renamed elsewhere, so the count never over-reports. */
const pruneChecked = (): void => {
  if (state.selectMode) {
    for (const id of state.checkedIds) {
      if (indexOfId(id) < 0) {
        state.checkedIds.delete(id);
      }
    }
  }
};

/** Redraws the sidebar, the status line and the toolbar from the session. */
export const renderList = (): void => {
  pruneChecked();
  ui.setShell({
    list: buildVmList({
      vms: state.vms,
      selected: state.selected,
      transitioning: state.transitioning,
      checked: state.checkedIds,
      selectMode: state.selectMode,
      filter: searchText(),
      folderOpen,
    }),
  });
  setStatusText(inventorySummary(state.vms, selectedVm()), state.statusLoading);
  updateCommandState();
};

// ── Summary panel ────────────────────────────────────────────────────

const dashboardView = (): SummaryView =>
  state.vms.length > 0
    ? { kind: "dashboard", rows: state.vms.map((vm, index) => ({ index, vm, brand: osBrand(vm.name, vm.os) })), host: state.host }
    : { kind: "welcome" };

/** Redraws the dashboard (or the welcome state) when the Summary panel is showing it. */
export const publishVms = (): void => {
  if (state.dashboardShown) {
    ui.setSummary(dashboardView());
  }
};

const fetchHost = (): void => {
  fetch("/api/host")
    .then((response) => response.json())
    .then((body: unknown) => {
      state.host = parseHost(body);
      publishVms();
    })
    .catch(() => undefined);
};

const summaryView = (vm: Vm): SummaryView => {
  if (state.lookups.id !== vm.id) {
    state.lookups = { ...LOADING_LOOKUPS, id: vm.id };
  }
  if (vm.status !== "running") {
    state.lookups = { ...state.lookups, ip: { kind: "loading" } };
  }
  return { kind: "vm", vm, folder: vmFolder(vm), guestIp: state.lookups.ip, diskUsage: state.lookups.disk, slots: state.slots };
};

/** Redraws the selected VM's summary (after a lookup arrived). */
const pushSummary = (): void => {
  const vm = selectedVm();
  if (vm !== null) {
    ui.setSummary(summaryView(vm));
  }
};

type Answer = { readonly ip: Lookup<string> } | { readonly disk: Lookup<DiskUsage> };

/** Stores a lookup that arrived after the draw, unless the selection moved on. */
const setLookup = (index: number, answer: Answer): void => {
  if (state.selected !== index || state.vms[index]?.id !== state.lookups.id) {
    return;
  }
  state.lookups = { ...state.lookups, ...answer };
  pushSummary();
};

const UNAVAILABLE_TEXT = "unavailable";
const NO_AGENT_TEXT = "unavailable, guest agent not running";

const loadGuestInfo = (index: number): void => {
  fetch(`/api/vms/${index}/guestinfo`, { headers: AUTH_HEADERS })
    .then((response) => (response.ok ? response.json() : Promise.reject(new Error("guestinfo"))))
    .then((body: unknown) => {
      const ips = parseGuestIps(body);
      setLookup(index, { ip: ips === "" ? { kind: "unavailable", text: NO_AGENT_TEXT } : { kind: "ready", value: ips } });
    })
    .catch(() => setLookup(index, { ip: { kind: "unavailable", text: UNAVAILABLE_TEXT } }));
};

const loadDiskInfo = (index: number): void => {
  fetch(`/api/vms/${index}/diskinfo`)
    .then((response) => (response.ok ? response.json() : Promise.reject(new Error("diskinfo"))))
    .then((body: unknown) => {
      const usage = parseDiskInfo(body);
      setLookup(index, { disk: usage === null ? { kind: "unavailable", text: UNAVAILABLE_TEXT } : { kind: "ready", value: usage } });
    })
    .catch(() => setLookup(index, { disk: { kind: "unavailable", text: UNAVAILABLE_TEXT } }));
};

/** The Summary panel for no selection: the host dashboard, or the welcome state without VMs. */
export const showEmptyState = (): void => {
  document.title = EMPTY_TITLE;
  state.activeTab = "summary";
  if (state.vms.length > 0 && !state.dashboardShown) {
    fetchHost();
  }
  state.dashboardShown = state.vms.length > 0;
  ui.setSummary(dashboardView());
  ui.closeSettings();
  state.settingsDirty = false;
  updateCommandState();
};

/** The Summary panel for the selected VM (or the empty state when nothing is selected). */
export const renderDetails = (): void => {
  const vm = selectedVm();
  if (vm === null || state.selected === null) {
    showEmptyState();
    return;
  }
  if (state.activeTab === "console" && !(vm.status === "running" && embeddedDisplayCapable(vm))) {
    state.activeTab = "summary";
  }
  document.title = `${PAGE_TITLE}${vm.name}`;
  state.dashboardShown = false;
  ui.setSummary(summaryView(vm));
  if (vm.hasDisk === "true") {
    loadDiskInfo(state.selected);
  }
  if (vm.status === "running") {
    loadGuestInfo(state.selected);
  }
  updateCommandState();
};

/** Redraws the panel for the current selection. */
export const syncPanels = (): void => {
  if (selectedVm() === null) {
    showEmptyState();
  } else {
    renderDetails();
  }
};
