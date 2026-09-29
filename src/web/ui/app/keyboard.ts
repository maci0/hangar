import { cloneGuest, importGuest, newVm, openPrefs, showShortcuts } from "@/app/dialogs";
import { deleteVm, reorderVm } from "@/app/library";
import { openPalette } from "@/app/menus";
import { refresh } from "@/app/poll";
import { confirmDiscard, deselectVm, editVm, select } from "@/app/session";
import { selectedVm, state } from "@/app/state";
import { renderList, showEmptyState } from "@/app/view";
import { powerToggle, suspendGuest } from "@/app/vm-actions";
import { ui } from "@/bridge";
import { settingsControl } from "@/components/settings";

const DISPLAY_ONLY_CLASS = "displayonly";

const isTextField = (target: EventTarget | null): boolean =>
  target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement;

/** True when the event came from a button or link, which handle Enter and Delete themselves. */
const fromControl = (target: EventTarget | null): boolean => target instanceof Element && target.closest("button, a[href]") !== null;

const focusSearch = (): void => {
  const input = document.querySelector<HTMLInputElement>("#search");
  input?.focus();
  input?.select();
};

/** Index the arrow key moves to: the ends when nothing is selected, else one step, kept inside the list. */
const stepTarget = (key: string): number => {
  const last = state.vms.length - 1;
  const step = key === "ArrowUp" ? -1 : 1;
  if (state.selected === null) {
    return step < 0 ? last : 0;
  }
  return Math.max(0, Math.min(last, state.selected + step));
};

/** Arrow keys inside the VM list move the selection. Returns whether the key was handled. */
const moveSelection = (event: KeyboardEvent): boolean => {
  const list = document.querySelector("#vmlist");
  if (!(event.target instanceof Node) || list === null || !list.contains(event.target)) {
    return false;
  }
  event.preventDefault();
  const next = stepTarget(event.key);
  void select(next).then(() => document.querySelector<HTMLElement>(`#vmlist .vm-item[data-vm-index="${next}"]`)?.focus());
  return true;
};

/** Alt with an arrow key moves the selected VM one place in the list. */
const moveSelectedVm = (event: KeyboardEvent): void => {
  const { selected } = state;
  if (selected === null) {
    return;
  }
  const to = selected + (event.key === "ArrowUp" ? -1 : 1);
  if (to >= 0 && to < state.vms.length) {
    event.preventDefault();
    reorderVm(selected, to);
  }
};

/** Escape closes, in order: toolbar menus, the context menu, open dialogs, display-only mode, the selection. */
const onEscape = async (): Promise<void> => {
  if (ui.closeToolbarMenus(true) || ui.closeContextMenu(true)) {
    return;
  }
  const open = document.querySelectorAll("dialog[open]");
  for (const dialog of open) {
    if (dialog instanceof HTMLDialogElement) {
      dialog.close();
    }
  }
  if (open.length > 0) {
    return;
  }
  if (document.body.classList.contains(DISPLAY_ONLY_CLASS)) {
    ui.exitDisplayOnly();
  } else if (state.selected !== null && (await confirmDiscard())) {
    state.selected = null;
    renderList();
    showEmptyState();
  }
};

const onF11 = (): void => {
  if (document.body.classList.contains(DISPLAY_ONLY_CLASS)) {
    ui.exitDisplayOnly();
  } else if (ui.displayConnected()) {
    ui.enterDisplayOnly();
  } else if (document.fullscreenElement === null) {
    document.documentElement.requestFullscreen().catch(() => undefined);
  } else {
    void document.exitFullscreen();
  }
};

/** Ctrl shortcuts, keyed by `event.key`. */
const CTRL_SHORTCUTS: Readonly<Record<string, (event: KeyboardEvent) => void>> = {
  n: (event) => (event.shiftKey ? cloneGuest() : newVm()),
  e: () => void editVm(),
  w: () => void deselectVm(),
  i: importGuest,
  s: () => void (selectedVm() === null ? undefined : suspendGuest()),
  p: () => void openPrefs(),
  f: focusSearch,
  Enter: () => void editVm(),
};

/** Keys that need no modifier and stand aside when a button or link has focus. */
const runPlainKey = (event: KeyboardEvent): boolean => {
  if (fromControl(event.target)) {
    return false;
  }
  if (event.key === "Delete") {
    void deleteVm();
    return true;
  }
  if (event.key === "Enter") {
    if (state.selected !== null) {
      void powerToggle();
    }
    return true;
  }
  return false;
};

const FUNCTION_KEYS: Readonly<Record<string, () => void>> = {
  F2: () => void editVm(),
  F5: () => void refresh(),
  F11: onF11,
};

const runShortcut = (event: KeyboardEvent): void => {
  const { key } = event;
  const ctrlShortcut = event.ctrlKey ? CTRL_SHORTCUTS[key] : undefined;
  const functionKey = FUNCTION_KEYS[key];
  if (key === "Escape") {
    void onEscape();
  } else if (key === "?" && !event.ctrlKey && !event.metaKey) {
    event.preventDefault();
    showShortcuts();
  } else if (ctrlShortcut !== undefined) {
    event.preventDefault();
    ctrlShortcut(event);
  } else if (functionKey !== undefined) {
    event.preventDefault();
    functionKey();
  } else if (!runPlainKey(event) && event.altKey && (key === "ArrowUp" || key === "ArrowDown")) {
    moveSelectedVm(event);
  }
};

const onKeyDown = (event: KeyboardEvent): void => {
  const modifier = event.ctrlKey || event.metaKey;
  if (modifier && event.key === "s" && state.activeTab === "settings" && state.selected !== null) {
    event.preventDefault();
    settingsControl.submit();
  } else if (modifier && (event.key === "k" || event.key === "K")) {
    event.preventDefault();
    openPalette();
  } else if (!isTextField(event.target) && !((event.key === "ArrowUp" || event.key === "ArrowDown") && moveSelection(event))) {
    runShortcut(event);
  }
};

/** Global shortcuts. Ctrl+K and Ctrl+S (in Settings) work in text fields; the rest stand aside for typing. */
export const listenKeyboard = (): void => {
  document.addEventListener("keydown", onKeyDown);
};
