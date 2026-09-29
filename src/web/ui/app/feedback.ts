import { ui } from "@/bridge";
import type { ShellState } from "@/components/app-shell";
import type { ToastType } from "@/components/toasts";
import { osBrand } from "@/lib/os-brand";
import { embeddedDisplayCapable } from "@/lib/vm";
import { selectedVm, state } from "@/app/state";

const NARROW_QUERY = "(max-width: 900px)";
const UNDO_TOAST_MS = 5000;

/** Below 900px the sidebar is an overlay opened over the page instead of a column. */
export const isNarrowLayout = (): boolean => globalThis.matchMedia(NARROW_QUERY).matches;

/** The search box text, or an empty string before the page is drawn. */
export const searchText = (): string => document.querySelector<HTMLInputElement>("#search")?.value ?? "";

const shellHeader = (): ShellState["header"] => {
  const vm = selectedVm();
  if (vm === null) {
    return {
      name: state.vms.length > 0 ? "Overview" : "Welcome to Hangar",
      emblem: null,
      tabsVisible: false,
      activeTab: "summary",
      consoleEnabled: false,
    };
  }
  const brand = osBrand(vm.name, vm.os);
  return {
    name: vm.name,
    emblem: { text: brand.text, color: brand.color },
    tabsVisible: true,
    activeTab: state.activeTab,
    consoleEnabled: vm.status === "running" && embeddedDisplayCapable(vm),
  };
};

/** Pushes the chrome (banner, sidebar head, bulk bar, header, status bar, sidebar position) from the session. */
export const syncShell = (): void => {
  const expanded = isNarrowLayout() ? state.sidebarOpen : !state.sidebarCollapsed;
  ui.setShell({
    selectMode: state.selectMode,
    checkedCount: state.checkedIds.size,
    searchActive: searchText() !== "",
    bannerVisible: state.serverDown,
    header: shellHeader(),
    status: { text: state.statusText, loading: state.statusLoading },
    live: state.streamLive,
    announcement: state.announcement,
    loading: state.loadBar,
    sidebar: { collapsed: state.sidebarCollapsed, overlayOpen: state.sidebarOpen, expanded },
  });
  ui.setToolbar({ sidebarExpanded: expanded });
};

/** Sets the load bar over the page. */
export const setLoadBar = (on: boolean): void => {
  state.loadBar = on;
  syncShell();
};

/** Passive status text (list summary, uptime). Never announced. */
export const setStatusText = (text: string, isLoading: boolean): void => {
  state.statusText = text;
  state.statusLoading = isLoading;
  syncShell();
};

const announce = (text: string): void => {
  state.announcement = text;
  syncShell();
};

/** Status text that screen readers hear as well. */
export const setStatus = (text: string): void => {
  setStatusText(text, false);
  announce(text);
};

/** Pulsing `text…` in the bar; screen readers hear `text`. */
export const setStatusLoading = (text: string): void => {
  setStatusText(`${text}…`, true);
  announce(text);
};

export type ToastOptions = { readonly duration?: number };

export const showToast = (message: string, type: ToastType = "info", options: ToastOptions = {}): void => {
  ui.showToast({ message, type, duration: options.duration });
};

/** A toast with an UNDO button that runs `onUndo`. */
export const toastUndo = (message: string, onUndo: () => void): void => {
  ui.showToast({ message, type: "info", duration: UNDO_TOAST_MS, undo: onUndo });
};
