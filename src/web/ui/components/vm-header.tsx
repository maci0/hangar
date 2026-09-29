import { cn } from "@/lib/cn";

export type TabId = "console" | "summary" | "settings";

export type VmHeaderProps = {
  /** Heading text: the selected VM, or the overview or welcome title. */
  readonly name: string;
  /** OS monogram and its brand color; null when no VM is selected. */
  readonly emblem: { readonly text: string; readonly color: string } | null;
  /** Tabs show only while a VM is selected. */
  readonly tabsVisible: boolean;
  readonly activeTab: TabId;
  /** The console tab needs a running VM with an embedded display. */
  readonly consoleEnabled: boolean;
  readonly onSwitchTab: (tab: TabId) => void;
};

type TabDef = {
  readonly id: TabId;
  readonly label: string;
  readonly panel: string;
};

const TABS: ReadonlyArray<TabDef> = [
  { id: "console", label: "Console", panel: "tabConsole" },
  { id: "summary", label: "Summary", panel: "tabSummary" },
  { id: "settings", label: "Settings", panel: "tabSettings" },
];

const CONSOLE_DISABLED_TITLE = "Console requires a running embedded VNC or SPICE display";
const CONSOLE_TITLE = "Open VM console";
const consoleTitle = (enabled: boolean): string => (enabled ? CONSOLE_TITLE : CONSOLE_DISABLED_TITLE);
const TAB_KEYS: ReadonlySet<string> = new Set(["ArrowLeft", "ArrowRight", "Home", "End"]);

const tabTarget = (key: string, current: number, count: number): number => {
  if (key === "Home") {
    return 0;
  }
  if (key === "End") {
    return count - 1;
  }
  return (current + (key === "ArrowRight" ? 1 : -1) + count) % count;
};

/**
 * Arrow/Home/End move to another enabled tab and activate it. Activation is the tab's own click,
 * so `onSwitchTab` (and its unsaved-changes guard) runs as for a pointer.
 */
const onTabKeyDown = (event: KeyboardEvent & { readonly currentTarget: HTMLElement }) => {
  if (!TAB_KEYS.has(event.key)) {
    return;
  }
  const tabs = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="tab"]:not([disabled])')];
  const current = event.target instanceof HTMLButtonElement ? tabs.indexOf(event.target) : -1;
  if (current === -1) {
    return;
  }
  event.preventDefault();
  const next = tabs[tabTarget(event.key, current, tabs.length)];
  next?.click();
  next?.focus();
};

const TabButton = ({ tab, selected, disabled, title, onSelect }: {
  readonly onSelect: () => void;
  readonly tab: TabDef;
  readonly selected: boolean;
  readonly disabled: boolean;
  readonly title: string | undefined;
}) => (
  <button
    id={`tab-btn-${tab.id}`}
    type="button"
    class={cn(
      "-mb-px inline-flex items-center border-0 border-b-2 border-transparent bg-transparent px-3.5 py-1.5 text-field font-medium text-fg-muted transition-colors hover:border-border-hover hover:text-fg focus-visible:outline-2 -outline-offset-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-42 disabled:hover:border-transparent disabled:hover:text-fg-muted pointer-coarse:min-h-11",
      selected && "border-accent font-semibold text-fg hover:border-accent",
    )}
    onClick={onSelect}
    role="tab"
    tabIndex={selected ? 0 : -1}
    aria-controls={tab.panel}
    aria-selected={selected}
    disabled={disabled}
    title={title}
  >
    {tab.label}
  </button>
);

/** Heading row above the tab panels: VM emblem and name on the left, the view tabs on the right. */
export const VmHeader = ({ name, emblem, tabsVisible, activeTab, consoleEnabled, onSwitchTab }: VmHeaderProps) => (
  <div class="vm-header mb-3 flex items-center justify-between gap-4 max-narrow:flex-col max-narrow:items-stretch max-narrow:gap-2 displayonly:hidden">
    <div class="flex min-w-0 items-center">
      {emblem !== null && (
        <span
          id="vmemblem"
          class="mr-2.5 inline-flex size-7.5 flex-none items-center justify-center rounded-md text-title leading-none font-bold text-white"
          style={{ background: emblem.color }}
        >
          {emblem.text}
        </span>
      )}
      <h2 id="vmname" class="m-0 text-heading leading-tight font-semibold text-fg wrap-anywhere max-narrow:text-title">
        {name}
      </h2>
    </div>
    {tabsVisible && (
      <div
        id="tabBar"
        class="tab-bar flex gap-0.5 border-b border-border max-narrow:overflow-x-auto"
        role="tablist"
        aria-label="VM views"
        onKeyDown={onTabKeyDown}
      >
        {TABS.map((tab) => (
          <TabButton
            key={tab.id}
            tab={tab}
            onSelect={() => onSwitchTab(tab.id)}
            selected={tab.id === activeTab}
            disabled={tab.id === "console" && !consoleEnabled}
            title={tab.id === "console" ? consoleTitle(consoleEnabled) : undefined}
          />
        ))}
      </div>
    )}
  </div>
);
