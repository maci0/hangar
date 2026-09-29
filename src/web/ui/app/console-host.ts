import { apiPost } from "@/app/api";
import { setStatus, showToast } from "@/app/feedback";
import { indexOfId, state } from "@/app/state";
import type { ConsoleHost } from "@/console-bridge";

/** Sends Ctrl+Alt+Del to the selected guest. */
export const sendCad = async (): Promise<void> => {
  const { selected } = state;
  if (selected === null) {
    return;
  }
  if (await apiPost(`/api/vms/${selected}/cad`)) {
    setStatus("Ctrl+Alt+Del sent to guest.");
  }
};

/** What the console controllers (display, serial, migration) use from the session. */
export const consoleHost: ConsoleHost = {
  selected: () => state.selected,
  vmAt: (index) => state.vms[index],
  // The controllers report failures through their own state; there is no debug log to write to.
  log: () => undefined,
  post: apiPost,
  indexOfId,
  announce: setStatus,
  toast: (message, type) => showToast(message, type),
};
