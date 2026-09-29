import { render } from "preact";
import { AppShell, type ShellHandlers, type ShellState } from "@/components/app-shell";
import { ContextMenu, type ContextMenuRequest } from "@/components/context-menu";
import { MAX_TOASTS, Toasts, type ToastEntry, type ToastRequest } from "@/components/toasts";
import type { ToolbarProps } from "@/components/toolbar";

const INITIAL: ShellState = {
  selectMode: false,
  checkedCount: 0,
  searchActive: false,
  bannerVisible: false,
  header: { name: "Select a VM", emblem: null, tabsVisible: false, activeTab: "summary", consoleEnabled: false },
  status: { text: "Ready", loading: false },
  live: false,
  announcement: "",
  loading: false,
  sidebar: { collapsed: false, overlayOpen: false, expanded: true },
  list: { favorites: [], folders: [], ungrouped: [], selectMode: false, filtered: false },
  toolbar: {
    sidebarExpanded: false,
    hasVm: false,
    powered: false,
    batchBusy: null,
    actionReason: () => null,
  },
};

export type ShellBridge = {
  /** Hands over what the chrome calls back into and draws the page. Call once, before any state. */
  readonly bindShell: (handlers: ShellHandlers) => void;
  /** Merges the given fields into the chrome state and redraws it. */
  readonly setShell: (patch: Partial<ShellState>) => void;
  /** Merges the given fields into the toolbar state and redraws it. */
  readonly setToolbar: (patch: Partial<Omit<ToolbarProps, "handlers">>) => void;
};

/** Draws the page into `#app`; the panel bridges draw into the empty mounts it leaves. */
export const createShellBridge = (): ShellBridge => {
  let state = INITIAL;
  let handlers: ShellHandlers | null = null;
  const draw = (): void => {
    const root = document.querySelector("#app");
    if (root && handlers !== null) {
      render(<AppShell state={state} handlers={handlers} />, root);
    }
  };
  return {
    bindShell: (next) => {
      handlers = next;
      draw();
    },
    setShell: (patch) => {
      state = { ...state, ...patch };
      draw();
    },
    setToolbar: (patch) => {
      state = { ...state, toolbar: { ...state.toolbar, ...patch } };
      draw();
    },
  };
};

export type OverlayBridge = {
  /** Draws the toast container (a live region that must exist before the first toast). Call once the page is drawn. */
  readonly mountOverlay: () => void;
  /** Shows a toast; the oldest goes when more than five are up. */
  readonly showToast: (request: ToastRequest) => void;
  /** Opens the VM context menu at a viewport point, replacing any open one. */
  readonly openContextMenu: (request: Omit<ContextMenuRequest, "id">) => void;
  /** Closes the context menu; returns whether one was open. `returnFocus` refocuses its VM row. */
  readonly closeContextMenu: (returnFocus: boolean) => boolean;
};

type OverlayState = {
  toasts: ReadonlyArray<ToastEntry>;
  menu: ContextMenuRequest | null;
  nextId: number;
};

/** Toast stack and context menu share `#overlay-root`; the toast container stays mounted (live region). */
export const createOverlayBridge = (): OverlayBridge => {
  const state: OverlayState = { toasts: [], menu: null, nextId: 0 };
  const actions = {
    draw: (): void => {
      const root = document.querySelector("#overlay-root");
      if (root) {
        render(
          <>
            <Toasts toasts={state.toasts} onDone={actions.removeToast} />
            {state.menu && <ContextMenu request={state.menu} onClose={actions.dismissMenu} />}
          </>,
          root,
        );
      }
    },
    removeToast: (id: number): void => {
      state.toasts = state.toasts.filter((toast) => toast.id !== id);
      actions.draw();
    },
    dismissMenu: (): void => {
      state.menu = null;
      actions.draw();
    },
  };

  return {
    mountOverlay: actions.draw,
    showToast: (request) => {
      state.nextId += 1;
      state.toasts = [...state.toasts, { ...request, id: state.nextId }].slice(-MAX_TOASTS);
      actions.draw();
    },
    openContextMenu: (request) => {
      state.nextId += 1;
      state.menu = { ...request, id: state.nextId };
      actions.draw();
    },
    closeContextMenu: (returnFocus) => {
      if (state.menu === null) {
        return false;
      }
      const { vmIndex } = state.menu;
      actions.dismissMenu();
      if (returnFocus) {
        document.querySelector<HTMLElement>(`#vmlist .vm-item[data-vm-index="${vmIndex}"]`)?.focus();
      }
      return true;
    },
  };
};
