import { apiPost } from "@/app/api";
import { setStatus, showToast, toastUndo } from "@/app/feedback";
import { refresh, reloadList } from "@/app/poll";
import { select } from "@/app/session";
import { indexOfId, indexOfName, selectedVm, state } from "@/app/state";
import { renderDetails, renderList } from "@/app/view";
import { ui } from "@/bridge";
import type { NewVmValues } from "@/components/dialogs/new-vm";
import { folderNames, folderOpen, setFolderOpen, vmFolder } from "@/lib/folders";
import type { Vm } from "@/lib/vm";

const enc = encodeURIComponent;

/** Snapshot tags must not hold control characters or `..`, and stay under this length. */
const TAG_MAX = 255;
const CONTROL_OR_DOTS = /\p{Cc}|\.\./u;

// ── Create, import, clone, delete ────────────────────────────────────

export const createVm = async (values: NewVmValues): Promise<boolean> => {
  let body = `name=${enc(values.name)}&mem=${values.memoryMb}&cpu=${values.cpuCores}&disk=${values.diskGb}`;
  body += `&guest_os=${enc(values.guestOs)}&firmware=${enc(values.firmware)}`;
  if (values.isoPath !== "") {
    body += `&iso_path=${enc(values.isoPath)}`;
  }
  if ((await apiPost("/api/vms", body)) === null) {
    return false;
  }
  await refresh();
  const index = indexOfName(values.name);
  if (index >= 0) {
    await select(index);
  }
  setStatus("VM created.");
  return true;
};

export const quickstartVm = async (slug: string): Promise<boolean> => {
  if ((await apiPost(`/api/vms/quickstart/${slug}`)) === null) {
    return false;
  }
  await refresh();
  setStatus("VM created from template.");
  return true;
};

/** Imports a disk image; renames the new VM when `wantName` is given, then selects it. */
export const importVm = async (path: string, wantName: string): Promise<boolean> => {
  const before = new Set(state.vms.map((vm) => vm.name));
  if ((await apiPost("/api/vms/import", `path=${enc(path)}`)) === null) {
    return false;
  }
  await refresh();
  let added = state.vms.findIndex((vm) => !before.has(vm.name));
  const importedName = state.vms[added]?.name;
  if (wantName !== "" && importedName !== undefined && importedName !== wantName) {
    await apiPost(`/api/vms/${added}/rename`, `name=${enc(wantName)}`);
    await refresh();
    added = indexOfName(wantName);
  }
  if (added >= 0) {
    await select(added);
  }
  setStatus("VM imported.");
  return true;
};

export const cloneVm = async (linked: boolean): Promise<boolean> => {
  const index = state.selected;
  if (index === null || (await apiPost(`/api/vms/${index}/clone`, linked ? "linked=1" : "")) === null) {
    return false;
  }
  await refresh();
  setStatus(linked ? "Linked clone created." : "VM cloned.");
  return true;
};

export const deleteVm = async (): Promise<void> => {
  const vm = selectedVm();
  if (vm === null || !(await ui.confirm(`Delete VM "${vm.name}"?`, { danger: true, okLabel: "Delete" }))) {
    return;
  }
  const index = indexOfId(vm.id);
  if (index < 0 || (await apiPost(`/api/vms/${index}/delete`)) === null) {
    return;
  }
  state.selected = null;
  await refresh();
  toastUndo(`Deleted "${vm.name}"`, () => {
    void (async () => {
      await apiPost("/api/vms/undo");
      await refresh();
    })();
  });
};

// ── Favorites, folders, order ────────────────────────────────────────

export const toggleFavorite = async (index: number): Promise<void> => {
  const vm = state.vms[index];
  if (vm === undefined) {
    return;
  }
  const favorite = vm.favorite === "true" ? "0" : "1";
  if ((await apiPost(`/api/vms/${index}`, `favorite=${favorite}`)) === null) {
    return;
  }
  const current = state.vms[index];
  if (current !== undefined) {
    state.vms[index] = { ...current, favorite: favorite === "1" ? "true" : "false" };
  }
  renderList();
  if (state.selected === index) {
    renderDetails();
  }
};

export const toggleFolder = (name: string): void => {
  setFolderOpen(name, !folderOpen(name));
  renderList();
};

export const moveToFolder = async (): Promise<void> => {
  const vm = selectedVm();
  if (vm === null) {
    return;
  }
  const answer = await ui.prompt(`Move "${vm.name}" to folder (blank = none):`, vmFolder(vm), folderNames(state.vms));
  if (answer === null) {
    return;
  }
  const folder = answer.trim();
  const index = indexOfId(vm.id);
  if (index >= 0 && (await apiPost(`/api/vms/${index}`, `folder=${enc(folder)}`))) {
    await refresh();
    setStatus(folder === "" ? "Removed from folder" : `Moved to ${folder}`);
  }
};

/** Moves the VM at `from` to position `to`: instantly in the list, undoable, undone locally if the daemon refuses. */
export const reorderVm = (from: number, to: number): void => {
  if (state.saveInFlight) {
    return;
  }
  const previousSelection = state.selected;
  const moved = state.vms[from];
  if (moved === undefined) {
    return;
  }
  // The poll stands still while the request is out.
  state.saveInFlight = true;
  const reordered = state.vms.filter((_, index) => index !== from);
  reordered.splice(to, 0, moved);
  state.vms = reordered;
  state.selected = to;
  renderList();
  renderDetails();
  void (async () => {
    const response = await apiPost("/api/vms/reorder", `from=${from}&to=${to}`);
    state.saveInFlight = false;
    if (response !== null) {
      await refresh();
      toastUndo(`Moved "${moved.name}"`, () => {
        void (async () => {
          if (await apiPost("/api/vms/reorder", `from=${to}&to=${from}`)) {
            state.selected = previousSelection;
            await refresh();
          }
        })();
      });
      return;
    }
    // Put the VM back where it was, and the selection too unless the user changed it meanwhile.
    const restored = state.vms.filter((vm) => vm !== moved);
    restored.splice(from, 0, moved);
    state.vms = restored;
    if (state.selected === to) {
      state.selected = previousSelection;
    }
    renderList();
    renderDetails();
  })();
};

// ── Search, select mode and bulk operations ──────────────────────────

export const clearSearch = (): void => {
  const input = document.querySelector<HTMLInputElement>("#search");
  if (input !== null) {
    input.value = "";
  }
  renderList();
};

export const toggleSelectMode = (): void => {
  state.selectMode = !state.selectMode;
  if (!state.selectMode) {
    state.checkedIds.clear();
  }
  renderList();
};

export const toggleCheck = (id: string, checked: boolean): void => {
  if (checked) {
    state.checkedIds.add(id);
  } else {
    state.checkedIds.delete(id);
  }
  renderList();
};

const NONE_SELECTED = "No VMs selected";

/** Runs `run(index, id)` for each checked VM, re-reading the list before each so deletes cannot shift an index. */
const bulkRun = async (label: string, run: (index: number, vm: Vm) => Promise<boolean>): Promise<void> => {
  const ids = [...state.checkedIds];
  if (ids.length === 0) {
    showToast(NONE_SELECTED, "warn");
    return;
  }
  let ok = 0;
  let failed = 0;
  for (const id of ids) {
    await reloadList();
    const index = indexOfId(id);
    const vm = state.vms[index];
    if (vm !== undefined) {
      const done = await run(index, vm).catch(() => false);
      if (done) {
        ok += 1;
      } else {
        failed += 1;
      }
    }
  }
  setStatus(`${label}: ${ok} ok${failed > 0 ? `, ${failed} failed` : ""}`);
  await refresh();
};

const isPowered = (vm: Vm): boolean => vm.status === "running" || vm.status === "paused";

export const bulkPower = async (on: boolean): Promise<void> => {
  const count = state.checkedIds.size;
  if (count === 0) {
    showToast(NONE_SELECTED, "warn");
    return;
  }
  const verb = on ? "Power on" : "Power off";
  const options = on ? { okLabel: "Power On" } : { danger: true, okLabel: "Power Off" };
  if (!(await ui.confirm(`${verb} ${count} selected VM(s)?`, options))) {
    return;
  }
  await bulkRun(verb, (index, vm) =>
    isPowered(vm) === on ? Promise.resolve(true) : apiPost(`/api/vms/${index}${on ? "/start" : "/stop"}`).then((response) => response !== null),
  );
};

export const bulkSnapshot = async (): Promise<void> => {
  const count = state.checkedIds.size;
  if (count === 0) {
    showToast(NONE_SELECTED, "warn");
    return;
  }
  const answer = await ui.prompt(`Snapshot name for ${count} selected VM(s):`, "bulk-snapshot", []);
  if (answer === null) {
    return;
  }
  const tag = answer.trim();
  if (tag === "") {
    showToast("Enter a snapshot name", "warn");
    return;
  }
  if (CONTROL_OR_DOTS.test(tag) || tag.length > TAG_MAX) {
    showToast("Snapshot name is invalid", "error");
    return;
  }
  await bulkRun("Snapshot", (index) => apiPost(`/api/vms/${index}/snapshots`, `tag=${enc(tag)}`).then((response) => response !== null));
};

export const bulkDelete = async (): Promise<void> => {
  const count = state.checkedIds.size;
  if (count === 0) {
    showToast(NONE_SELECTED, "warn");
    return;
  }
  if (!(await ui.confirm(`Delete ${count} selected VM(s)? Undo restores them one at a time.`, { danger: true, okLabel: "Delete" }))) {
    return;
  }
  await bulkRun("Delete", (index) => apiPost(`/api/vms/${index}/delete`).then((response) => response !== null));
  state.checkedIds.clear();
  renderList();
};

// ── Batch power (Manage menu) ────────────────────────────────────────

/** Runs a power request for each VM in `ids`, reporting progress in the status line. */
const batchRun = async (verb: "start" | "stop", ids: ReadonlyArray<string>): Promise<{ readonly done: number; readonly failed: number }> => {
  let done = 0;
  let failed = 0;
  for (const id of ids) {
    const index = indexOfId(id);
    if (index >= 0) {
      setStatus(`Batch ${verb}: VM ${done + failed + 1} of ${ids.length}...`);
      if ((await apiPost(`/api/vms/${index}/${verb}`)) === null) {
        failed += 1;
        setStatus(`Batch ${verb}: VM ${done + failed} of ${ids.length} failed, continuing...`);
      } else {
        done += 1;
      }
    }
  }
  return { done, failed };
};

const finishBatch = async (verb: "start" | "stop", tally: { readonly done: number; readonly failed: number }): Promise<void> => {
  await refresh();
  const past = verb === "start" ? "started" : "stopped";
  setStatus(`Batch ${verb} complete: ${tally.done} ${past}${tally.failed > 0 ? `, ${tally.failed} failed` : ""}`);
  ui.setToolbar({ batchBusy: null });
};

export const batchStart = async (): Promise<void> => {
  ui.setToolbar({ batchBusy: "batchStart" });
  const ids = state.vms.filter((vm) => vm.status === "stopped").map((vm) => vm.id);
  await finishBatch("start", await batchRun("start", ids));
};

export const batchStop = async (): Promise<void> => {
  if (!(await ui.confirm("Power off ALL running VMs?\nUnsaved data may be lost.", { danger: true, okLabel: "Power Off All" }))) {
    return;
  }
  ui.setToolbar({ batchBusy: "batchStop" });
  const ids = state.vms.filter(isPowered).map((vm) => vm.id).toReversed();
  await finishBatch("stop", await batchRun("stop", ids));
};

