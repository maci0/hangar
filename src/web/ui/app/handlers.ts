import { setStatus, syncShell } from "@/app/feedback";
import { batchStart, batchStop, bulkDelete, bulkPower, bulkSnapshot, clearSearch, deleteVm, moveToFolder, reorderVm, toggleCheck, toggleFavorite, toggleFolder, toggleSelectMode } from "@/app/library";
import { cloneGuest, importGuest, migrateGuest, newVm, openAbout, openCatalog, openPrefs, openSnapshots, openVnets, showShortcuts, viewLog } from "@/app/dialogs";
import { openContextMenu, toggleTheme } from "@/app/menus";
import { deselectVm, editVm, select, switchTab } from "@/app/session";
import { createSettingsTools } from "@/app/settings-tools";
import { closeSidebar, toggleSidebar } from "@/app/sidebar";
import { state } from "@/app/state";
import { exportOvf, pauseGuest, powerToggle, renameGuest, resetGuest, resumeGuest, shutdownGuest, suspendGuest, takeScreenshot } from "@/app/vm-actions";
import { renderList } from "@/app/view";
import { sendCad } from "@/app/console-host";
import { ui, type UiHandlers } from "@/bridge";
import type { ToolbarHandlers } from "@/components/toolbar";

/** Search runs this long after the last keystroke. */
const SEARCH_DEBOUNCE_MS = 180;

const searchDebounce: { timer: ReturnType<typeof setTimeout> | null } = { timer: null };

const search = (): void => {
  if (searchDebounce.timer !== null) {
    clearTimeout(searchDebounce.timer);
  }
  searchDebounce.timer = setTimeout(renderList, SEARCH_DEBOUNCE_MS);
};

const settingsTools = createSettingsTools(() => void editVm());

const toolbar: ToolbarHandlers = {
  toggleSidebar,
  deselectVm: () => void deselectVm(),
  powerToggle: () => void powerToggle(),
  newVm,
  editVm: () => void editVm(),
  cycleTheme: toggleTheme,
  menu: {
    powerToggle: () => void powerToggle(),
    shutdownGuest: () => void shutdownGuest(),
    suspendGuest: () => void suspendGuest(),
    pauseGuest: () => void pauseGuest(),
    resumeGuest: () => void resumeGuest(),
    resetGuest: () => void resetGuest(),
    takeSnapshot: openSnapshots,
    openSnapshots,
    changeCd: settingsTools.changeCd,
    ejectCd: settingsTools.ejectCd,
    sendCad: () => void sendCad(),
    reconnectDisplay: () => ui.reconnectDisplay(),
    enterDisplayOnly: () => ui.enterDisplayOnly(),
    manualDisconnectSerial: () => ui.disconnectSerial(),
    renameGuest: () => void renameGuest(),
    moveToFolder: () => void moveToFolder(),
    cloneGuest,
    migrateGuest,
    exportOvf: () => void exportOvf(),
    importGuest,
    openCatalog: () => void openCatalog(),
    openVnets: () => void openVnets(),
    openPrefs: () => void openPrefs(),
    showShortcutsModal: showShortcuts,
    openAbout,
    batchStart: () => void batchStart(),
    batchStop: () => void batchStop(),
    deleteVm: () => void deleteVm(),
  },
};

/** Everything the surfaces call back into, wired once at start. */
export const uiHandlers: UiHandlers = {
  shell: {
    list: {
      select: (index) => void select(index),
      toggleFavorite: (index) => void toggleFavorite(index),
      toggleCheck,
      toggleFolder,
      clearSearch,
      newVm,
      contextMenu: openContextMenu,
      closeContextMenu: () => void ui.closeContextMenu(false),
      reorder: reorderVm,
    },
    toolbar,
    search,
    clearSearch,
    toggleSelectMode,
    bulkPower: (on) => void bulkPower(on),
    bulkSnapshot: () => void bulkSnapshot(),
    bulkDelete: () => void bulkDelete(),
    switchTab: (tab) => void switchTab(tab),
    dismissBanner: () => {
      state.serverDown = false;
      syncShell();
      setStatus("");
    },
    closeSidebar,
  },
  panels: {
    library: { newVm, importVm: importGuest, openCatalog: () => void openCatalog() },
    selectVm: (index) => void select(index),
    viewLog,
    screenshot: () => void takeScreenshot(),
    settingsTools,
    cancelSettings: () => void switchTab("summary"),
  },
};
