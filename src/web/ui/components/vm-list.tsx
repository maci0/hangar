import { Button } from "@/components/ui/button";
import { Icon } from "@/components/icon";

export type VmStatus = "running" | "paused" | "suspended" | "stopped";

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

export type VmListProps = {
  readonly favorites: ReadonlyArray<VmRow>;
  readonly folders: ReadonlyArray<VmFolder>;
  readonly ungrouped: ReadonlyArray<VmRow>;
  readonly selectMode: boolean;
  readonly filtered: boolean;
};

const STATUS_LABEL: Readonly<Record<VmStatus, string>> = {
  running: "Running",
  paused: "Paused",
  suspended: "Suspended",
  stopped: "Stopped",
};

const Row = ({ row, selectMode }: { readonly row: VmRow; readonly selectMode: boolean }) => {
  const label = STATUS_LABEL[row.status];
  const dotClass = row.status === "stopped" ? "dot" : `dot ${row.status}`;
  const itemClass = ["vm-item", row.active && "active", row.transitioning && "transitioning", selectMode && "selectable"]
    .filter(Boolean)
    .join(" ");
  return (
    <div class="vm-row">
      <div
        class={itemClass}
        role="button"
        aria-current={row.active ? "true" : undefined}
        data-vm-index={row.index}
        tabIndex={row.tabStop ? 0 : -1}
        data-action="select"
        draggable
        title={row.name}
      >
        {selectMode && (
          <input
            type="checkbox"
            class="vm-check"
            data-action="toggleCheck"
            data-vm-id={row.id}
            checked={row.checked}
            aria-label={`Select ${row.name}`}
          />
        )}
        <span class={dotClass} role="img" aria-label={label} title={label} />
        {row.name}
        <div class="vm-meta" aria-hidden="true">
          {row.meta}
        </div>
      </div>
      <button
        type="button"
        class={row.favorite ? "star fav" : "star"}
        data-vm-index={row.index}
        data-action="toggleFavorite"
        aria-pressed={row.favorite}
        aria-label={row.favorite ? "Remove from favorites" : "Add to favorites"}
      >
        <Icon name="star" />
      </button>
    </div>
  );
};

const Rows = ({ rows, selectMode }: { readonly rows: ReadonlyArray<VmRow>; readonly selectMode: boolean }) =>
  rows.map((row) => <Row key={row.id} row={row} selectMode={selectMode} />);

const Empty = ({ filtered }: { readonly filtered: boolean }) =>
  filtered ? (
    <div class="sidebar-empty">
      <p>No matching VMs</p>
      <Button data-action="clearSearch">Clear search</Button>
    </div>
  ) : (
    <div class="sidebar-empty">
      <p>No virtual machines yet</p>
      <Button variant="primary" data-action="newVm">
        <Icon name="plus" />
        New VM
      </Button>
    </div>
  );

/** Sidebar VM library: favorites, then folders, then ungrouped VMs. */
export const VmList = ({ favorites, folders, ungrouped, selectMode, filtered }: VmListProps) => {
  const empty = favorites.length === 0 && folders.length === 0 && ungrouped.length === 0;
  if (empty) {
    return <Empty filtered={filtered} />;
  }
  const showSeparator = favorites.length > 0 && (folders.length > 0 || ungrouped.length > 0);
  return (
    <>
      <Rows rows={favorites} selectMode={selectMode} />
      {showSeparator && <div role="separator" aria-hidden="true" class="vm-list-sep" />}
      {folders.map((folder) => (
        <div key={folder.name}>
          <div
            class={folder.open ? "folder-hdr open" : "folder-hdr"}
            data-action="toggleFolder"
            data-folder={folder.name}
            role="button"
            tabIndex={0}
            aria-expanded={folder.open}
          >
            <span class="folder-caret" aria-hidden="true">
              ▸
            </span>
            <span class="folder-name">{folder.name}</span>
            <span class="folder-count">{folder.rows.length}</span>
          </div>
          {folder.open && (
            <div class="folder-body">
              <Rows rows={folder.rows} selectMode={selectMode} />
            </div>
          )}
        </div>
      ))}
      <Rows rows={ungrouped} selectMode={selectMode} />
    </>
  );
};
