import { writeInFlight } from "@/app/api";
import { setStatus, syncShell } from "@/app/feedback";
import { selectedVm, state } from "@/app/state";
import { publishVms, renderDetails, renderList, showEmptyState } from "@/app/view";
import { ui } from "@/bridge";
import type { TabId } from "@/components/vm-header";
import { parseVmList } from "@/lib/inventory";
import { embeddedDisplayCapable, type Vm } from "@/lib/vm";

/** Longest a poll may wait for the daemon. */
const POLL_TIMEOUT_MS = 15_000;
export const POLL_INTERVAL_MS = 5000;
const HTTP_SERVER_ERROR = 500;

/** Shows another VM view without the unsaved-changes check (the caller has done it, or it cannot apply). */
export const showTab = (tab: TabId): void => {
  state.activeTab = tab;
  syncShell();
};

export const setServerDown = (down: boolean): void => {
  state.serverDown = down;
  syncShell();
  if (down) {
    setStatus("Server unreachable, retrying...");
  }
};

/** A poll answer: the list, the daemon down or failing (server error, no answer, not JSON), or a client-error status (ignored). */
type Poll = { readonly kind: "list"; readonly vms: Array<Vm> } | { readonly kind: "down" } | { readonly kind: "ignored" };

const DOWN: Poll = { kind: "down" };

const fetchList = async (): Promise<Poll> => {
  const response = await fetch("/api/vms", { signal: AbortSignal.timeout(POLL_TIMEOUT_MS) }).catch((): null => null);
  if (response === null) {
    return DOWN;
  }
  if (!response.ok) {
    return response.status >= HTTP_SERVER_ERROR ? DOWN : { kind: "ignored" };
  }
  const body: unknown = await response.json().catch((): undefined => undefined);
  const vms = parseVmList(body);
  return vms === null ? DOWN : { kind: "list", vms };
};

/** Follows a status change of the selected VM: console on when it starts, off when it stops. */
const followStatusChange = (before: { readonly name: string; readonly status: string } | null): void => {
  const vm = selectedVm();
  if (before === null || vm === null || vm.name !== before.name || vm.status === before.status || state.selected === null) {
    return;
  }
  if (vm.status === "running") {
    ui.startDisplay();
    ui.startSerial(state.selected);
    if (state.activeTab === "summary" && embeddedDisplayCapable(vm)) {
      showTab("console");
    }
  } else {
    ui.stopDisplay();
    ui.stopSerial(true);
    if (state.activeTab === "console") {
      showTab("summary");
    }
  }
};

/** Reloads the VM list and redraws. Stands still while a write, a save or a power change runs. */
export const refresh = async (): Promise<void> => {
  if (document.hidden || state.refreshBusy || state.transitioning !== null || state.saveInFlight || writeInFlight()) {
    return;
  }
  state.refreshBusy = true;
  try {
    const before = selectedVm();
    const remembered = before === null ? null : { name: before.name, status: before.status };
    const poll = await fetchList();
    if (poll.kind !== "list") {
      if (poll.kind === "down" && !state.serverDown) {
        setServerDown(true);
      }
      return;
    }
    setServerDown(false);
    state.vms = poll.vms;
    publishVms();
    // The selection may have moved during the fetch; only follow a change of the VM that was sampled.
    followStatusChange(remembered);
    renderList();
    if (state.selected === null) {
      showEmptyState();
    } else if (selectedVm() !== null) {
      renderDetails();
    }
  } finally {
    state.refreshBusy = false;
  }
};

/** Re-syncs the list from the daemon right now (bulk runs), skipping the poll's guards. */
export const reloadList = async (): Promise<void> => {
  const poll = await fetchList();
  if (poll.kind === "list") {
    state.vms = poll.vms;
    publishVms();
  }
};
