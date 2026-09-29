import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";

export type SidebarHeadProps = {
  /** Multi-select is on: the rows show checkboxes and the bulk bar is open. */
  readonly selectMode: boolean;
  /** The search box holds text, so its clear button shows. */
  readonly searchActive: boolean;
};

const TOGGLE_LABEL = "Select multiple VMs";

/**
 * Sidebar title row and search box. The input is uncontrolled: `app.js` reads its value when it
 * redraws the list, and the delegated `filterList` action debounces the input event.
 */
export const SidebarHead = ({ selectMode, searchActive }: SidebarHeadProps) => (
  <>
    <div class="sidebar-header flex min-h-10 items-center gap-2 border-b border-border-soft px-3 py-2">
      <div
        class="logo flex size-5.5 items-center justify-center rounded-sm bg-accent text-xs font-bold text-on-accent"
        aria-hidden="true"
      >
        H
      </div>
      <h2 class="text-field font-semibold tracking-wide text-fg">Hangar</h2>
      <button
        id="selectToggle"
        type="button"
        class={cn(
          "ml-auto inline-flex size-6 items-center justify-center rounded-sm border border-transparent bg-transparent text-fg-dim transition-colors hover:border-border-hover hover:text-fg focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent aria-pressed:border-accent aria-pressed:bg-accent-soft aria-pressed:text-accent pointer-coarse:size-11",
        )}
        data-action="toggleSelectMode"
        aria-pressed={selectMode}
        title="Select multiple VMs (bulk actions)"
        aria-label={TOGGLE_LABEL}
      >
        <Icon name="check" class="ico size-3.75" />
      </button>
    </div>
    <div class="relative px-2.5 py-2">
      <Icon name="search" class="ico pointer-events-none absolute top-1/2 left-4.5 size-3 -translate-y-1/2 text-fg-dim" />
      <input
        id="search"
        type="search"
        class="no-search-cancel empty-hint h-6.5 w-full rounded-md border border-border bg-bg px-6.5 text-xs text-fg outline-none hover:border-border-hover focus-visible:border-accent focus-visible:ring-2 focus-visible:ring-accent-soft"
        placeholder="Search VMs…"
        data-action="filterList"
        aria-label="Search VMs"
        autocomplete="off"
      />
      {searchActive && (
        <button
          id="searchClear"
          type="button"
          class="absolute top-1/2 right-3 inline-flex size-6 -translate-y-1/2 items-center justify-center rounded-sm border-0 bg-transparent p-0 text-fg-dim hover:bg-surface-2 hover:text-fg focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent pointer-coarse:size-11"
          data-action="clearSearch"
          aria-label="Clear search"
        >
          <Icon name="x" class="ico size-3.5" />
        </button>
      )}
    </div>
  </>
);

export type BulkBarProps = {
  readonly selectMode: boolean;
  readonly checkedCount: number;
};

const BULK_BUTTON = "min-h-5.5 gap-1 px-1.75 py-0.5 text-caption";
const BULK_ICON = "ico size-3";

/** Actions for the checked rows; open only in select mode. */
export const BulkBar = ({ selectMode, checkedCount }: BulkBarProps) =>
  selectMode && (
    <div
      id="bulkBar"
      class="bulk-bar flex flex-col gap-1.5 border-t border-border bg-bg-alt px-2.5 py-2"
      role="toolbar"
      aria-label="Bulk actions"
    >
      <span id="bulkCount" class="text-caption font-semibold text-fg-muted">
        {checkedCount} selected
      </span>
      <div class="flex flex-wrap gap-1">
        <Button class={BULK_BUTTON} data-action="bulkPower" data-on="1" title="Power on selected">
          <Icon name="power" class={BULK_ICON} />
          On
        </Button>
        <Button class={BULK_BUTTON} data-action="bulkPower" data-on="0" title="Power off selected">
          <Icon name="power" class={BULK_ICON} />
          Off
        </Button>
        <Button class={BULK_BUTTON} data-action="bulkSnapshot" title="Snapshot selected">
          <Icon name="snapshot" class={BULK_ICON} />
          Snapshot
        </Button>
        <Button variant="danger" class={BULK_BUTTON} data-action="bulkDelete" title="Delete selected">
          <Icon name="trash" class={BULK_ICON} />
          Delete
        </Button>
      </div>
      <Button data-action="toggleSelectMode" title="Exit select mode">
        Done
      </Button>
    </div>
  );
