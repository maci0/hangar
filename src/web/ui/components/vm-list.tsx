import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { useReorder, type Reorder } from "@/components/vm-list-reorder";
import { clsx } from "clsx";
import type { VmStatus } from "@/lib/vm";

export type VmRow = {
  readonly index: number;
  readonly id: string;
  readonly name: string;
  readonly status: VmStatus;
  readonly meta: string;
  readonly favorite: boolean;
  readonly active: boolean;
  readonly transitioning: boolean;
  readonly checked: boolean;
  readonly tabStop: boolean;
};

export type VmFolder = {
  readonly name: string;
  readonly open: boolean;
  readonly rows: ReadonlyArray<VmRow>;
};

/** What the list asks of the app. Indexes are list positions; `id` is the stable VM id. */
export type ListHandlers = {
  readonly select: (index: number) => void;
  readonly toggleFavorite: (index: number) => void;
  readonly toggleCheck: (id: string, checked: boolean) => void;
  readonly toggleFolder: (name: string) => void;
  readonly clearSearch: () => void;
  readonly newVm: () => void;
  /** Opens the VM menu for the row at `index`, at a viewport point. */
  readonly contextMenu: (index: number, x: number, y: number) => void;
  readonly closeContextMenu: () => void;
  readonly reorder: (from: number, to: number) => void;
};

export type VmListProps = {
  readonly favorites: ReadonlyArray<VmRow>;
  readonly folders: ReadonlyArray<VmFolder>;
  readonly ungrouped: ReadonlyArray<VmRow>;
  readonly selectMode: boolean;
  readonly filtered: boolean;
  readonly handlers: ListHandlers;
};

const STATUS_LABEL: Readonly<Record<VmStatus, string>> = {
  running: "Running",
  paused: "Paused",
  suspended: "Suspended",
  stopped: "Stopped",
};

const DOT_TONE: Readonly<Record<VmStatus, string>> = {
  running: "running bg-success shadow-dot-success animate-dot-breathe motion-reduce:animate-none",
  paused: "paused bg-pause shadow-dot-pause",
  suspended: "suspended bg-warn shadow-dot-warn",
  stopped: "bg-fg-dim",
};

const ROW_FOCUS = "focus-visible:outline-2 -outline-offset-2 focus-visible:outline-accent";
/** How far into the row the keyboard-opened context menu appears. */
const CONTEXT_ANCHOR_INSET_PX = 24;
const ITEM_BASE =
  "relative mb-px grid min-h-9.5 grid-cols-vm-row items-center gap-1.75 rounded-sm border border-l-2 border-transparent px-2 py-1.25 pr-8 text-field text-fg-muted transition-colors hover:bg-surface-2 hover:text-fg pointer-coarse:min-h-12 pointer-coarse:pr-13";
const ITEM_SELECTABLE = "grid-cols-vm-row-select pl-1.5";
/** The star sits over the row's right edge; the row keeps room for it. */
const STAR =
  "absolute top-1.75 right-1 inline-flex min-h-6 min-w-6 cursor-pointer items-center justify-center rounded-sm border-0 bg-transparent p-0 text-caption leading-none text-fg-dim aria-pressed:text-accent-3 pointer-coarse:top-0.5 pointer-coarse:min-h-11 pointer-coarse:min-w-11";

const isContextKey = (event: KeyboardEvent): boolean => event.key === "ContextMenu" || (event.shiftKey && event.key === "F10");

type RowProps = {
  readonly row: VmRow;
  readonly selectMode: boolean;
  readonly handlers: ListHandlers;
  readonly reorder: Reorder;
};

const rowKeyDown = (event: KeyboardEvent & { readonly currentTarget: HTMLElement }, row: VmRow, handlers: ListHandlers): void => {
  if (event.target !== event.currentTarget) {
    return;
  }
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    handlers.select(row.index);
  } else if (isContextKey(event)) {
    event.preventDefault();
    event.stopPropagation();
    const box = event.currentTarget.getBoundingClientRect();
    handlers.contextMenu(row.index, box.left + Math.min(CONTEXT_ANCHOR_INSET_PX, box.width / 2), box.bottom);
  }
};

const RowItem = ({ row, selectMode, handlers, reorder }: RowProps) => {
  const label = STATUS_LABEL[row.status];
  return (
    <div
      class={clsx(
        "vm-item",
        ITEM_BASE,
        ROW_FOCUS,
        selectMode && `selectable ${ITEM_SELECTABLE}`,
        row.active && "active border-l-accent bg-accent-soft font-semibold text-fg",
        row.transitioning && "transitioning pointer-events-none opacity-55",
        reorder.drag?.from === row.index && "dragging opacity-35",
        reorder.drag?.over === row.index && "drag-over border-t-accent",
      )}
      role="button"
      aria-current={row.active ? "true" : undefined}
      data-vm-index={row.index}
      tabIndex={row.tabStop ? 0 : -1}
      title={row.name}
      onClick={() => handlers.select(row.index)}
      onKeyDown={(event) => rowKeyDown(event, row, handlers)}
      onContextMenu={(event) => {
        event.preventDefault();
        event.stopPropagation();
        handlers.contextMenu(row.index, event.clientX, event.clientY);
      }}
      {...reorder.rowProps(row.index)}
    >
      {selectMode && (
        <input
          type="checkbox"
          class="vm-check m-0 mr-1.5 size-3.75 flex-none cursor-pointer accent-accent"
          checked={row.checked}
          aria-label={`Select ${row.name}`}
          onClick={(event) => event.stopPropagation()}
          onChange={(event) => handlers.toggleCheck(row.id, event.currentTarget.checked)}
        />
      )}
      <span class={clsx("dot size-1.75 rounded-full", DOT_TONE[row.status])} role="img" aria-label={label} title={label} />
      {row.name}
      <div class={clsx("vm-meta mt-0.5 truncate pl-4.5 text-caption text-fg-dim", row.active && "text-fg-muted")} aria-hidden="true">
        {row.meta}
      </div>
    </div>
  );
};

const Row = (props: RowProps) => (
  <div class="vm-row relative">
    <RowItem {...props} />
    <button
      type="button"
      class={clsx("star", STAR, ROW_FOCUS, props.row.favorite && "fav")}
      aria-pressed={props.row.favorite}
      aria-label={props.row.favorite ? "Remove from favorites" : "Add to favorites"}
      onClick={() => props.handlers.toggleFavorite(props.row.index)}
    >
      <Icon name="star" class={clsx("ico size-3", props.row.favorite && "fill-current stroke-current")} />
    </button>
  </div>
);

const Empty = ({ filtered, handlers }: { readonly filtered: boolean; readonly handlers: ListHandlers }) => (
  <div class="sidebar-empty flex flex-col items-center gap-2 px-3.5 py-6 text-center">
    {filtered ? (
      <>
        <p class="text-xs leading-normal text-fg-dim">No matching VMs</p>
        <Button class="w-full max-w-45" onClick={handlers.clearSearch}>
          Clear search
        </Button>
      </>
    ) : (
      <>
        <p class="text-xs leading-normal text-fg-dim">No virtual machines yet</p>
        <Button variant="primary" class="w-full max-w-45" onClick={handlers.newVm}>
          <Icon name="plus" />
          New VM
        </Button>
      </>
    )}
  </div>
);

const FolderHeader = ({ folder, onToggle }: { readonly folder: VmFolder; readonly onToggle: () => void }) => (
  <div
    class={clsx(
      "folder-hdr flex min-h-6.5 cursor-pointer items-center gap-1.5 rounded-sm px-2 py-0.75 text-caption tracking-wider text-fg-dim uppercase transition-colors select-none hover:bg-surface-2 hover:text-fg-muted",
      ROW_FOCUS,
      folder.open && "open",
    )}
    data-folder={folder.name}
    role="button"
    tabIndex={0}
    aria-expanded={folder.open}
    onClick={onToggle}
    onKeyDown={(event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onToggle();
      }
    }}
  >
    <span class={clsx("folder-caret inline-block text-caption text-fg-dim transition-transform", folder.open && "rotate-90")} aria-hidden="true">
      ▸
    </span>
    <span class="folder-name flex-1 truncate font-semibold">{folder.name}</span>
    <span class="folder-count rounded-xs bg-surface-2 px-1.25 text-caption text-fg-dim">{folder.rows.length}</span>
  </div>
);

/** Sidebar VM library: favorites, then folders, then ungrouped VMs. */
export const VmList = ({ favorites, folders, ungrouped, selectMode, filtered, handlers }: VmListProps) => {
  const reorder = useReorder(handlers.reorder);
  const rows = (list: ReadonlyArray<VmRow>) =>
    list.map((row) => <Row key={row.id} row={row} selectMode={selectMode} handlers={handlers} reorder={reorder} />);
  if (favorites.length === 0 && folders.length === 0 && ungrouped.length === 0) {
    return <Empty filtered={filtered} handlers={handlers} />;
  }
  const showSeparator = favorites.length > 0 && (folders.length > 0 || ungrouped.length > 0);
  return (
    <div class="contents" onContextMenu={handlers.closeContextMenu}>
      {rows(favorites)}
      {showSeparator && <div role="separator" aria-hidden="true" class="vm-list-sep mx-2 my-1 h-px bg-border" />}
      {folders.map((folder) => (
        <div key={folder.name}>
          <FolderHeader folder={folder} onToggle={() => handlers.toggleFolder(folder.name)} />
          {folder.open && <div class="folder-body ml-2 border-l border-border-soft pl-0.75">{rows(folder.rows)}</div>}
        </div>
      ))}
      {rows(ungrouped)}
    </div>
  );
};
