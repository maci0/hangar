import { apiPost } from "@/app/api";
import { setStatus, showToast } from "@/app/feedback";
import { refresh, showTab } from "@/app/poll";
import { closeSidebar } from "@/app/sidebar";
import { selectedVm, state } from "@/app/state";
import { renderDetails, renderList, showEmptyState, updateCommandState } from "@/app/view";
import { ui } from "@/bridge";
import type { TabId } from "@/components/vm-header";
import { messageOf } from "@/lib/api";
import { embeddedDisplayCapable } from "@/lib/vm";

const DISCARD_PROMPT = "You have unsaved changes. Discard them?";

/** Asks whether unsaved Settings edits may go; true when there are none. */
export const confirmDiscard = (): Promise<boolean> =>
  state.activeTab !== "settings" || !state.settingsDirty ? Promise.resolve(true) : ui.confirm(DISCARD_PROMPT, { danger: true, okLabel: "Discard" });

/** Persists the body the Settings form built, then refreshes and returns to Summary. */
const persistSettings = async (body: string): Promise<boolean> => {
  const index = state.selected;
  if (index === null) {
    return false;
  }
  state.saveInFlight = true;
  try {
    if ((await apiPost(`/api/vms/${index}`, body)) === null) {
      setStatus("Save failed.");
      return false;
    }
    state.settingsDirty = false;
    // Clear the flag first: refresh stands still while it is set, and the summary would show stale data.
    state.saveInFlight = false;
    const failure = await refresh().then(
      (): null => null,
      (error: unknown) => messageOf(error, "request failed"),
    );
    if (failure !== null) {
      setStatus(`Save failed: ${failure}`);
      return false;
    }
    showTab("summary");
    setStatus("Settings saved.");
    return true;
  } finally {
    state.saveInFlight = false;
  }
};

const openSettingsForm = (): void => {
  const vm = selectedVm();
  if (vm === null) {
    return;
  }
  state.settingsDirty = false;
  ui.openSettings({
    vm,
    slots: state.slots,
    save: persistSettings,
    onDirty: (dirty) => {
      state.settingsDirty = dirty;
    },
    onInvalid: () => showToast("Fix highlighted settings before saving.", "error"),
  });
};

/** Switches the VM view; leaving Settings with unsaved edits asks first. */
export const switchTab = async (tab: TabId): Promise<void> => {
  if (state.activeTab === tab || (tab !== "settings" && !(await confirmDiscard()))) {
    return;
  }
  showTab(tab);
  if (tab === "settings" && state.selected !== null) {
    openSettingsForm();
  }
};

/** Opens the Settings tab for the selected VM, asking before it drops unsaved edits. */
export const editVm = async (): Promise<void> => {
  if (state.selected === null || !(await confirmDiscard())) {
    return;
  }
  if (state.activeTab === "settings") {
    openSettingsForm();
  } else {
    await switchTab("settings");
  }
};

/** Selects the VM at `index`, restarting the console for it. */
export const select = async (index: number): Promise<void> => {
  if (index === state.selected || !(await confirmDiscard())) {
    return;
  }
  state.settingsDirty = false;
  ui.stopDisplay();
  ui.stopSerial(true);
  state.selected = index;
  renderList();
  closeSidebar();
  ui.closeToolbarMenus(false);
  const vm = selectedVm();
  if (vm === null) {
    showEmptyState();
  } else {
    if (vm.status === "running" && embeddedDisplayCapable(vm) && state.activeTab !== "settings") {
      state.activeTab = "console";
    }
    if (state.activeTab === "settings") {
      void editVm();
    } else {
      renderDetails();
    }
    if (vm.status === "running") {
      ui.startDisplay();
      ui.startSerial(index);
    }
  }
  updateCommandState();
};

/** Clears the selection and shows the host dashboard. */
export const deselectVm = async (): Promise<void> => {
  if (!(await confirmDiscard())) {
    return;
  }
  ui.stopDisplay();
  ui.stopSerial(true);
  state.selected = null;
  renderList();
  showEmptyState();
  updateCommandState();
};
