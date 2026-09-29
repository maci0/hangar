import { showToast } from "@/app/feedback";
import { cloneGuest, importGuest, migrateGuest, newVm, openCatalog, openPrefs, openSnapshots, openVnets, showShortcuts } from "@/app/dialogs";
import { deleteVm, moveToFolder, toggleFavorite } from "@/app/library";
import { refresh } from "@/app/poll";
import { editVm, select, switchTab } from "@/app/session";
import { indexOfName, selectedVm, state } from "@/app/state";
import { exportOvf, pauseGuest, powerToggle, renameGuest, resetGuest, resumeGuest, shutdownGuest, suspendGuest } from "@/app/vm-actions";
import { sendCad } from "@/app/console-host";
import { ui } from "@/bridge";
import type { PaletteCommand } from "@/components/dialogs/palette";
import { actionAllowed, disabledReason, type VmAction } from "@/lib/actions";
import { cycleTheme } from "@/lib/theme";
import type { Vm } from "@/lib/vm";

const THEME_TOAST_MS = 2000;

/** Cycles the theme and says which one is on. */
export const toggleTheme = (): void => {
  const next = cycleTheme();
  showToast(`Theme: ${next.charAt(0).toUpperCase()}${next.slice(1)}`, "info", { duration: THEME_TOAST_MS });
};

// ── VM context menu ──────────────────────────────────────────────────

type MenuItem = {
  readonly label: string;
  readonly icon: string;
  readonly action: VmAction;
  readonly danger?: true;
  readonly run: (index: number) => void;
};

const contextItems = (on: boolean): ReadonlyArray<MenuItem | "separator"> => [
  { label: on ? "Power Off" : "Power On", icon: on ? "stop" : "play", action: "power-toggle", run: () => void powerToggle() },
  { label: "Shut Down Guest", icon: "power", action: "shutdown", run: () => void shutdownGuest() },
  { label: "Suspend", icon: "import", action: "suspend", run: () => void suspendGuest() },
  { label: "Pause", icon: "pause", action: "pause", run: () => void pauseGuest() },
  { label: "Resume", icon: "play", action: "resume", run: () => void resumeGuest() },
  "separator",
  { label: "Take Snapshot…", icon: "snapshot", action: "snapshot", run: openSnapshots },
  { label: "Snapshot Manager…", icon: "grid", action: "snapshot", run: openSnapshots },
  { label: "Open Console", icon: "terminal", action: "display", run: () => void switchTab("console") },
  { label: "Send Ctrl+Alt+Del", icon: "keyboard", action: "cad", run: () => void sendCad() },
  { label: "Display Only", icon: "maximize", action: "display", run: () => ui.enterDisplayOnly() },
  "separator",
  { label: "Settings", icon: "gear", action: "settings", run: () => void editVm() },
  { label: "Move to Folder…", icon: "folder", action: "settings", run: () => void moveToFolder() },
  { label: "Rename…", icon: "edit", action: "rename", run: () => void renameGuest() },
  { label: "Clone…", icon: "copy", action: "clone", run: cloneGuest },
  { label: "Migrate…", icon: "migrate", action: "migrate", run: migrateGuest },
  { label: "Export to OVF", icon: "export", action: "export", run: () => void exportOvf() },
  { label: "Toggle Favorite", icon: "star", action: "settings", run: (index) => void toggleFavorite(index) },
  "separator",
  { label: "Reset", icon: "refresh", action: "reset", danger: true, run: () => void resetGuest() },
  { label: "Delete", icon: "trash", action: "delete", danger: true, run: () => void deleteVm() },
];

/** Opens the VM menu for the row at `index` at a viewport point; an item selects the VM first, then runs. */
export const openContextMenu = (index: number, x: number, y: number): void => {
  const vm = state.vms[index];
  if (vm === undefined) {
    ui.closeContextMenu(false);
    return;
  }
  const on = vm.status === "running" || vm.status === "paused";
  ui.openContextMenu({
    vmIndex: index,
    x,
    y,
    entries: contextItems(on).map((item) => {
      if (item === "separator") {
        return { kind: "separator" };
      }
      const allowed = actionAllowed(item.action, vm, state.vms);
      return {
        kind: "item",
        label: item.label,
        icon: item.icon,
        danger: item.danger === true,
        reason: allowed ? null : disabledReason(item.action, vm),
        run: () => {
          void select(index).then(() => {
            if (state.selected === index) {
              item.run(index);
            }
          });
        },
      };
    }),
  });
};

// ── Command palette ──────────────────────────────────────────────────

const goTo = (name: string): PaletteCommand => ({
  label: `Go to ${name}`,
  run: () => {
    const index = indexOfName(name);
    if (index >= 0) {
      void select(index);
    }
  },
});

const vmCommands = (vm: Vm): Array<PaletteCommand> => [
  { label: `${vm.status === "running" || vm.status === "paused" ? "Power Off" : "Power On"}, ${vm.name}`, run: () => void powerToggle() },
  { label: `Settings, ${vm.name}`, run: () => void editVm() },
  { label: `Take Snapshot, ${vm.name}`, run: openSnapshots },
  { label: `Clone, ${vm.name}`, run: cloneGuest },
  { label: `Rename, ${vm.name}`, run: () => void renameGuest() },
  { label: `Move to Folder, ${vm.name}`, run: () => void moveToFolder() },
  { label: `Delete, ${vm.name}`, run: () => void deleteVm() },
];

const paletteCommands = (): Array<PaletteCommand> => {
  const vm = selectedVm();
  return [
    { label: "New VM", icon: "plus", run: newVm },
    { label: "Import VM", icon: "import", run: importGuest },
    { label: "VM Catalog", icon: "grid", run: () => void openCatalog() },
    { label: "Virtual Network Editor", icon: "net", run: () => void openVnets() },
    { label: "Preferences", icon: "gear", run: () => void openPrefs() },
    { label: "Keyboard Shortcuts", icon: "keyboard", run: showShortcuts },
    { label: "Toggle Theme", icon: "theme", run: toggleTheme },
    { label: "Refresh Inventory", icon: "refresh", run: () => void refresh() },
    ...(vm === null ? [] : vmCommands(vm)),
    ...state.vms.map((item) => goTo(item.name)),
  ];
};

export const openPalette = (): void => ui.openPalette(paletteCommands());
