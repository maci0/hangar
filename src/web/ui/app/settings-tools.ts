import { apiPost } from "@/app/api";
import { setStatus, showToast } from "@/app/feedback";
import { refresh } from "@/app/poll";
import { indexOfId, selectedVm, state } from "@/app/state";
import { ui } from "@/bridge";
import type { SettingsTools } from "@/components/settings";
import { AUTH_HEADERS, messageOf, responseError } from "@/lib/api";

const enc = encodeURIComponent;
const DISK_ACCEPT = ".qcow2,.qcow,.vmdk,.vdi,.vhdx,.raw,.img";
const DOWNLOAD_CLEANUP_MS = 1000;

const changeCd = async (): Promise<void> => {
  const vm = selectedVm();
  if (vm === null) {
    return;
  }
  const path = await ui.prompt("Path to the CD/ISO image to mount:", vm.iso_path, []);
  const index = indexOfId(vm.id);
  if (path === null || path === "" || index < 0) {
    return;
  }
  if (await apiPost(`/api/vms/${index}/cdrom`, `path=${enc(path)}`)) {
    await refresh();
    setStatus(`CD/ISO changed.${state.vms[indexOfId(vm.id)]?.status === "running" ? "" : " Mounts on next boot."}`);
  }
};

const ejectCd = async (): Promise<void> => {
  const index = state.selected;
  if (index !== null && (await apiPost(`/api/vms/${index}/cdrom/eject`, ""))) {
    await refresh();
    setStatus("CD/ISO ejected.");
  }
};

const compactDisk = async (): Promise<void> => {
  const vm = selectedVm();
  if (vm === null) {
    return;
  }
  if (vm.status !== "stopped") {
    showToast("Power off the VM before compacting its disk", "warn");
    return;
  }
  const question = "Compact the primary disk? This rewrites the image to reclaim freed space (VM must stay off during the operation).";
  if (!(await ui.confirm(question))) {
    return;
  }
  const index = indexOfId(vm.id);
  if (index >= 0 && (await apiPost(`/api/vms/${index}/disk/compact`, ""))) {
    await refresh();
    setStatus("Primary disk compacted.");
  }
};

const resizeDisk = async (): Promise<void> => {
  const vm = selectedVm();
  if (vm === null) {
    return;
  }
  if (vm.status !== "stopped") {
    showToast("Power off the VM before resizing its disk", "warn");
    return;
  }
  const current = Number.parseInt(String(vm.disk), 10) || 0;
  const answer = await ui.prompt(`New primary disk size in GB (grow only; current ${current} GB):`, String(current), []);
  if (answer === null) {
    return;
  }
  const size = Number.parseInt(answer, 10);
  if (!Number.isFinite(size) || size <= current) {
    showToast(`Enter a size larger than ${current} GB`, "error");
    return;
  }
  const index = indexOfId(vm.id);
  if (index >= 0 && (await apiPost(`/api/vms/${index}/disk/resize`, `size=${size}`))) {
    await refresh();
    setStatus(`Primary disk resized to ${size} GB.`);
  }
};

/** Sends the file, then reloads the list; throws with the daemon's message when it refuses. */
const sendDisk2 = async (index: number, file: File): Promise<void> => {
  const form = new FormData();
  form.append("disk2", file);
  const response = await fetch(`/api/vms/${index}/disk2`, { method: "POST", body: form, headers: AUTH_HEADERS });
  if (!response.ok) {
    throw new Error(await responseError(response));
  }
  await refresh();
};

/** Uploads the file and reports how it went; `reopen` redraws the Settings form when the selection is still the same VM. */
const uploadFile = async (index: number, name: string, file: File, reopen: () => void): Promise<void> => {
  setStatus(`Uploading Disk 2 for "${name}"...`);
  const failure = await sendDisk2(index, file).then(
    (): null => null,
    (error: unknown) => messageOf(error, "request failed"),
  );
  if (failure !== null) {
    setStatus(`Upload failed: ${failure}`);
    showToast(`Disk 2 upload failed: ${failure}`, "error");
    return;
  }
  setStatus("Disk 2 uploaded successfully.");
  if (state.selected === index) {
    reopen();
  }
};

const uploadDisk2 = (reopen: () => void): void => {
  const index = state.selected;
  const vm = selectedVm();
  if (index === null || vm === null) {
    return;
  }
  const input = document.createElement("input");
  input.type = "file";
  input.accept = DISK_ACCEPT;
  input.addEventListener("change", () => {
    const file = input.files?.[0];
    if (file !== undefined) {
      void uploadFile(index, vm.name, file, reopen);
    }
  });
  input.click();
};

const downloadDisk2 = (): void => {
  const vm = selectedVm();
  if (state.selected === null || vm === null) {
    return;
  }
  const link = document.createElement("a");
  link.href = `/api/vms/${state.selected}/disk2/download`;
  link.download = `${vm.name}_disk2.qcow2`;
  document.body.append(link);
  link.click();
  setTimeout(() => link.remove(), DOWNLOAD_CLEANUP_MS);
};

/** The buttons of the Settings tab; `reopen` redraws the form after a change that alters it. */
export const createSettingsTools = (reopen: () => void): SettingsTools => ({
  changeCd: () => void changeCd(),
  ejectCd: () => void ejectCd(),
  resizeDisk: () => void resizeDisk(),
  compactDisk: () => void compactDisk(),
  disk2upload: () => uploadDisk2(reopen),
  disk2download: downloadDisk2,
});
