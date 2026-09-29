import { BulkBar, SidebarHead } from "@/components/sidebar";
import { ConnectionBanner, StatusBar } from "@/components/status-bar";
import { Toolbar, type ToolbarHandlers, type ToolbarProps } from "@/components/toolbar";
import { VmHeader, type TabId, type VmHeaderProps } from "@/components/vm-header";
import { VmList, type ListHandlers, type VmListProps } from "@/components/vm-list";
import { cn } from "@/lib/cn";

/** Where the sidebar is: collapsed on wide screens, or an overlay opened over the page on narrow ones. */
export type SidebarState = {
  readonly collapsed: boolean;
  readonly overlayOpen: boolean;
  /** Whether the sidebar can be reached now (open overlay on narrow screens, not collapsed on wide ones). */
  readonly expanded: boolean;
};

/** Everything the page chrome shows. The app derives it from its own state and pushes patches. */
export type ShellState = {
  readonly selectMode: boolean;
  readonly checkedCount: number;
  readonly searchActive: boolean;
  /** The daemon is unreachable and the banner has not been dismissed. */
  readonly bannerVisible: boolean;
  readonly header: Omit<VmHeaderProps, "onSwitchTab">;
  readonly status: { readonly text: string; readonly loading: boolean };
  readonly live: boolean;
  readonly announcement: string;
  /** A daemon request is pending: the bar over the page slides. */
  readonly loading: boolean;
  readonly sidebar: SidebarState;
  readonly list: Omit<VmListProps, "handlers">;
  readonly toolbar: Omit<ToolbarProps, "handlers">;
};

/** What the chrome asks of the app, besides the list and toolbar handlers (which travel with their props). */
export type ShellHandlers = {
  readonly list: ListHandlers;
  readonly toolbar: ToolbarHandlers;
  readonly search: () => void;
  readonly clearSearch: () => void;
  readonly toggleSelectMode: () => void;
  readonly bulkPower: (on: boolean) => void;
  readonly bulkSnapshot: () => void;
  readonly bulkDelete: () => void;
  readonly switchTab: (tab: TabId) => void;
  readonly dismissBanner: () => void;
  readonly closeSidebar: () => void;
};

const PANEL = "animate-panel-in";

const focusMain = (event: MouseEvent): void => {
  event.preventDefault();
  document.querySelector<HTMLElement>("#main-content")?.focus();
};

type PaneProps = { readonly state: ShellState; readonly handlers: ShellHandlers };

/** The VM library: head and search, the list, the bulk bar. An overlay on narrow screens, a column on wide ones. */
const SidebarPane = ({ state, handlers }: PaneProps) => {
  const { sidebar } = state;
  return (
    <aside
      id="sidebar"
      role="navigation"
      aria-label="VM Library"
      aria-hidden={!sidebar.expanded}
      inert={!sidebar.expanded}
      class={cn(
        "z-10 col-start-1 row-start-2 flex w-65 min-w-65 flex-col overflow-hidden border-r border-border bg-bg-alt transition duration-120 displayonly:hidden",
        "max-narrow:fixed max-narrow:inset-y-0 max-narrow:left-0 max-narrow:z-150 max-narrow:-translate-x-full max-narrow:shadow-lg",
        sidebar.overlayOpen && "max-narrow:translate-x-0",
        sidebar.collapsed && "narrow:pointer-events-none narrow:-translate-x-full narrow:opacity-0",
      )}
    >
      <SidebarHead
        selectMode={state.selectMode}
        searchActive={state.searchActive}
        onSearch={handlers.search}
        onClearSearch={handlers.clearSearch}
        onToggleSelectMode={handlers.toggleSelectMode}
      />
      <div id="vmlist" role="group" aria-label="VM Library" class="scrollbar-quiet flex-1 touch-pan-y overflow-y-auto px-1.5 pt-1 pb-5">
        <VmList {...state.list} handlers={handlers.list} />
      </div>
      <BulkBar
        selectMode={state.selectMode}
        checkedCount={state.checkedCount}
        onPower={handlers.bulkPower}
        onSnapshot={handlers.bulkSnapshot}
        onDelete={handlers.bulkDelete}
        onToggleSelectMode={handlers.toggleSelectMode}
      />
    </aside>
  );
};

type PanelProps = {
  readonly id: string;
  readonly tab: TabId;
  readonly active: TabId;
  readonly rootId: string;
  /** The panel stays in the page during display-only mode. */
  readonly keepInDisplayOnly?: boolean;
};

/** A tab panel with an empty mount that another bridge draws into. */
const TabPanel = ({ id, tab, active, rootId, keepInDisplayOnly = false }: PanelProps) => (
  <div
    id={id}
    role="tabpanel"
    aria-labelledby={`tab-btn-${tab}`}
    aria-hidden={tab !== active}
    class={cn(PANEL, tab !== active && "hidden", keepInDisplayOnly ? "displayonly:block" : "displayonly:hidden")}
  >
    <div id={rootId} class="contents" />
  </div>
);

/** The toolbar and the VM view: header with tabs, the three panels, the migration bar. */
const MainPane = ({ state, handlers }: PaneProps) => (
  <main
    id="main-content"
    tabIndex={-1}
    class="relative col-start-1 row-start-2 flex min-h-0 min-w-0 flex-col overflow-hidden bg-bg narrow:col-start-2 displayonly:col-span-full displayonly:row-span-full displayonly:flex displayonly:items-center displayonly:justify-center displayonly:bg-black displayonly:p-0"
  >
    <div
      id="loadbar"
      class={cn("pointer-events-none absolute inset-x-0 top-0 z-300 h-0.5 opacity-0 transition-opacity", state.loading && "active opacity-100")}
    >
      <span class="block h-full w-1/3 animate-loadbar bg-accent" />
    </div>
    <h1 class="sr-only">Hangar VM Manager</h1>
    <Toolbar {...state.toolbar} handlers={handlers.toolbar} />
    <div class="content-area scrollbar-quiet flex-1 overflow-y-auto px-5 pt-4 pb-15 max-narrow:px-3.5 max-narrow:pt-3.5 max-narrow:pb-17.5 max-phone:px-2.5 max-phone:pt-3 max-phone:pb-19 displayonly:block displayonly:scrollbar-gutter-auto displayonly:overflow-hidden displayonly:p-0">
      <VmHeader {...state.header} onSwitchTab={handlers.switchTab} />
      <TabPanel id="tabConsole" tab="console" active={state.header.activeTab} rootId="console-root" keepInDisplayOnly />
      <TabPanel id="tabSummary" tab="summary" active={state.header.activeTab} rootId="summary-root" />
      <TabPanel id="tabSettings" tab="settings" active={state.header.activeTab} rootId="settings-root" />
      <div id="mig_bar_container" class="displayonly:hidden" />
    </div>
  </main>
);

/**
 * The page: skip link, connection banner, sidebar, toolbar, tab panels and status bar. The surfaces
 * the other bridges draw (console, summary, settings, migration bar, toasts and context menu,
 * display-only bar, dialogs) are empty mounts here; Preact leaves foreign children alone.
 */
export const AppShell = ({ state, handlers }: PaneProps) => (
  <>
    <div
      class={cn(
        "grid h-screen min-w-80 grid-cols-app-narrow grid-rows-app overflow-hidden bg-bg text-fg",
        state.sidebar.collapsed ? "narrow:grid-cols-app-collapsed" : "narrow:grid-cols-app",
      )}
    >
      <a
        id="skip-link"
        href="#main-content"
        class="absolute top-0 left-0 z-999 -translate-y-full bg-accent px-3.5 py-1.75 text-xs font-semibold text-on-accent no-underline transition-transform focus-visible:translate-y-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        onClick={focusMain}
      >
        Skip to main content
      </a>
      <ConnectionBanner visible={state.bannerVisible} onDismiss={handlers.dismissBanner} />
      {state.sidebar.overlayOpen && <div class="fixed inset-0 z-140 bg-backdrop-overlay" aria-hidden="true" onClick={handlers.closeSidebar} />}
      <SidebarPane state={state} handlers={handlers} />
      <MainPane state={state} handlers={handlers} />
      <StatusBar {...state.status} live={state.live} announcement={state.announcement} />
    </div>
    <div id="overlay-root" />
    <div id="displayonly-root" class="contents" />
    <div id="dialog-root" />
  </>
);
