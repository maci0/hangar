import { apiPost } from "@/app/api";
import { setStatus, showToast } from "@/app/feedback";
import { refresh } from "@/app/poll";
import { indexOfId, indexOfName, selectedVm, state } from "@/app/state";
import { renderList, syncToolbar } from "@/app/view";
import { ui } from "@/bridge";
import { AUTH_HEADERS, messageOf, responseError } from "@/lib/api";
import type { Vm } from "@/lib/vm";

const enc = encodeURIComponent;

/** The selected VM with its current index, or null. */
const target = (): { readonly vm: Vm; readonly index: number } | null => {
  const vm = selectedVm();
  return vm === null || state.selected === null ? null : { vm, index: state.selected };
};

/** Current index of `vm` after an await: its list position may have changed. */
const indexAfter = (vm: Vm): number => (vm.id === "" ? indexOfName(vm.name) : indexOfId(vm.id));

const isPowered = (vm: Vm): boolean => vm.status === "running" || vm.status === "paused";

// ── Power and guest control ──────────────────────────────────────────

/** Power On, or Power Off after a confirmation. Uses `/start` and `/stop`, never `/power`, so a duplicate delivery cannot reverse the request. */
export const powerToggle = async (): Promise<void> => {
  const found = target();
  if (found === null) {
    return;
  }
  const stop = isPowered(found.vm);
  if (stop && !(await ui.confirm(`Power off VM "${found.vm.name}"?\nUnsaved data may be lost.`, { danger: true, okLabel: "Power Off" }))) {
    return;
  }
  const index = indexAfter(found.vm);
  if (index < 0) {
    return;
  }
  state.transitioning = index;
  renderList();
  const response = await apiPost(`/api/vms/${index}${stop ? "/stop" : "/start"}`);
  state.transitioning = null;
  if (response === null) {
    renderList();
    return;
  }
  const failure = await refresh().then(
    (): null => null,
    (error: unknown) => messageOf(error, "request failed"),
  );
  if (failure !== null) {
    setStatus(`Refresh after power toggle failed: ${failure}`);
    renderList();
  }
  syncToolbar();
};

const confirmAndPost = async (question: string, path: string, done: string, options: { readonly danger?: boolean; readonly okLabel?: string }): Promise<Response | null> => {
  const found = target();
  if (found === null || !(await ui.confirm(question.replace("{name}", found.vm.name), options))) {
    return null;
  }
  const index = indexAfter(found.vm);
  if (index < 0) {
    return null;
  }
  const response = await apiPost(`/api/vms/${index}/${path}`);
  if (response !== null) {
    setStatus(done);
  }
  return response;
};

export const shutdownGuest = async (): Promise<void> => {
  await confirmAndPost('Send ACPI shutdown to "{name}"?', "shutdown", "Shut down guest, ACPI power button sent.", {});
};

export const resetGuest = async (): Promise<void> => {
  await confirmAndPost('Reset guest "{name}"?\nUnsaved data in the guest may be lost.', "reset", "Reset guest, system_reset sent.", {
    danger: true,
    okLabel: "Reset",
  });
};

export const suspendGuest = async (): Promise<void> => {
  const response = await confirmAndPost(
    'Suspend VM "{name}" to disk?\nThe VM state will be saved and the VM will be paused.',
    "suspend",
    "Suspended VM to disk.",
    { okLabel: "Suspend" },
  );
  if (response !== null) {
    await refresh();
  }
};

export const pauseGuest = async (): Promise<void> => {
  const index = state.selected;
  if (index !== null && (await apiPost(`/api/vms/${index}/pause`))) {
    await refresh();
    setStatus("Paused guest, execution frozen.");
  }
};

export const resumeGuest = async (): Promise<void> => {
  const index = state.selected;
  if (index !== null && (await apiPost(`/api/vms/${index}/resume`))) {
    await refresh();
    setStatus("Resumed guest, execution continued.");
  }
};

export const renameGuest = async (): Promise<void> => {
  const found = target();
  if (found === null) {
    return;
  }
  const answer = await ui.prompt("Rename VM:", found.vm.name, []);
  if (answer === null) {
    return;
  }
  const name = answer.trim();
  if (name === "") {
    showToast("Name cannot be empty or whitespace", "error");
    return;
  }
  const index = indexAfter(found.vm);
  if (name !== found.vm.name && index >= 0 && (await apiPost(`/api/vms/${index}/rename`, `name=${enc(name)}`))) {
    await refresh();
    setStatus("VM renamed.");
  }
};

const OBJECT_URL_LIFETIME_MS = 60_000;

/** Downloads the VM as an OVA file. */
export const exportOvf = async (): Promise<void> => {
  const found = target();
  if (found === null) {
    return;
  }
  const response = await fetch(`/api/vms/${found.index}/export`, { method: "POST", headers: AUTH_HEADERS }).catch((error: unknown) => error);
  if (!(response instanceof Response)) {
    setStatus(`Export error: ${messageOf(response, "request failed")}`);
    return;
  }
  if (!response.ok) {
    setStatus(`Export failed: ${response.status}`);
    return;
  }
  const link = document.createElement("a");
  link.href = URL.createObjectURL(await response.blob());
  link.download = `${found.vm.name}.ova`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), OBJECT_URL_LIFETIME_MS);
  setStatus("Export downloaded.");
};

const SCREENSHOT_URL_LIFETIME_MS = 10_000;

/** Opens the guest's current screen in a new tab. */
export const takeScreenshot = async (): Promise<void> => {
  const index = state.selected;
  if (index === null) {
    return;
  }
  const response = await fetch(`/api/vms/${index}/screenshot`, { headers: AUTH_HEADERS }).catch((): null => null);
  if (response === null) {
    showToast("Screenshot failed", "error");
    return;
  }
  if (!response.ok) {
    showToast(`Screenshot failed: ${await responseError(response)}`, "error");
    return;
  }
  const link = document.createElement("a");
  link.href = URL.createObjectURL(await response.blob());
  link.target = "_blank";
  link.rel = "noopener";
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), SCREENSHOT_URL_LIFETIME_MS);
};
