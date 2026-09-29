import { render, type ComponentChild } from "preact";
import { ContextMenu, type ContextMenuRequest } from "@/components/context-menu";
import { BulkBar, SidebarHead } from "@/components/sidebar";
import { ConnectionBanner, StatusBar } from "@/components/status-bar";
import { MAX_TOASTS, Toasts, type ToastEntry, type ToastRequest } from "@/components/toasts";
import { VmHeader, type VmHeaderProps } from "@/components/vm-header";

/** Everything the page chrome shows. `app.js` derives it from its own state and pushes patches. */
export type ShellState = {
  readonly selectMode: boolean;
  readonly checkedCount: number;
  readonly searchActive: boolean;
  /** The daemon is unreachable and the banner has not been dismissed. */
  readonly bannerVisible: boolean;
  readonly header: VmHeaderProps;
  readonly status: { readonly text: string; readonly loading: boolean };
  readonly live: boolean;
  readonly announcement: string;
};

const INITIAL: ShellState = {
  selectMode: false,
  checkedCount: 0,
  searchActive: false,
  bannerVisible: false,
  header: { name: "Select a VM", emblem: null, tabsVisible: false, activeTab: "summary", consoleEnabled: false },
  status: { text: "Ready", loading: false },
  live: false,
  announcement: "",
};

const mount = (selector: string, node: ComponentChild): void => {
  const root = document.querySelector(selector);
  if (root) {
    render(node, root);
  }
};

export type ShellBridge = {
  /** Merges the given fields into the chrome state and redraws it. */
  readonly setShell: (patch: Partial<ShellState>) => void;
};

export const createShellBridge = (): ShellBridge => {
  let state = INITIAL;
  const draw = (): void => {
    mount("#banner-root", <ConnectionBanner visible={state.bannerVisible} />);
    mount("#sidebar-head-root", <SidebarHead selectMode={state.selectMode} searchActive={state.searchActive} />);
    mount("#bulk-root", <BulkBar selectMode={state.selectMode} checkedCount={state.checkedCount} />);
    mount("#vmheader-root", <VmHeader {...state.header} />);
    mount("#statusbar-root", <StatusBar {...state.status} live={state.live} announcement={state.announcement} />);
  };
  draw();
  return {
    setShell: (patch) => {
      state = { ...state, ...patch };
      draw();
    },
  };
};

export type OverlayBridge = {
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
      mount(
        "#overlay-root",
        <>
          <Toasts toasts={state.toasts} onDone={actions.removeToast} />
          {state.menu && <ContextMenu request={state.menu} onClose={actions.dismissMenu} />}
        </>,
      );
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
  actions.draw();

  return {
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
