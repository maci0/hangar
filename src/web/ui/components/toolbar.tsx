import { useEffect, useRef, useState } from "preact/hooks";
import { Icon } from "@/components/icon";
import { ThemeToggle } from "@/components/theme-toggle";
import { Button } from "@/components/ui/button";
import { Menu, MenuItem, menuIconClass, MenuSeparator } from "@/components/ui/menu";
import type { VmAction } from "@/lib/actions";
import { cn } from "@/lib/cn";

type MenuId = "powerMenu" | "snapshotMenu" | "devicesMenu" | "toolsMenu" | "dangerMenu";

/** Every entry of the five menus. `data-action` carries the name as a hook for tests; the click runs the handler. */
export type MenuAction =
  | "powerToggle"
  | "shutdownGuest"
  | "suspendGuest"
  | "pauseGuest"
  | "resumeGuest"
  | "resetGuest"
  | "takeSnapshot"
  | "openSnapshots"
  | "changeCd"
  | "ejectCd"
  | "sendCad"
  | "reconnectDisplay"
  | "enterDisplayOnly"
  | "manualDisconnectSerial"
  | "renameGuest"
  | "moveToFolder"
  | "cloneGuest"
  | "migrateGuest"
  | "exportOvf"
  | "importGuest"
  | "openCatalog"
  | "openVnets"
  | "openPrefs"
  | "showShortcutsModal"
  | "openAbout"
  | "batchStart"
  | "batchStop"
  | "deleteVm";

type Item = {
  readonly action: MenuAction;
  /** Availability rule (`actionAllowed`); absent means always enabled. */
  readonly vmAction?: VmAction;
  readonly icon: string;
  readonly label: string;
  readonly danger?: boolean;
};

type MenuDef = {
  readonly id: MenuId;
  readonly trigger: string;
  readonly label: string;
  /** Menus about the selected VM stay disabled until one is selected. */
  readonly needsVm: boolean;
  /** The Manage trigger reads as destructive inside the More popover. */
  readonly danger?: boolean;
  readonly entries: ReadonlyArray<Item | "separator">;
};

const MENUS: ReadonlyArray<MenuDef> = [
  {
    id: "powerMenu",
    trigger: "Power ▾",
    label: "Power actions",
    needsVm: true,
    entries: [
      { action: "powerToggle", vmAction: "power-on", icon: "play", label: "Power On" },
      { action: "shutdownGuest", vmAction: "shutdown", icon: "power", label: "Shut Down Guest" },
      { action: "suspendGuest", vmAction: "suspend", icon: "import", label: "Suspend" },
      { action: "pauseGuest", vmAction: "pause", icon: "pause", label: "Pause" },
      { action: "resumeGuest", vmAction: "resume", icon: "play", label: "Resume" },
      "separator",
      { action: "resetGuest", vmAction: "reset", icon: "refresh", label: "Reset", danger: true },
      { action: "powerToggle", vmAction: "hard-power", icon: "stop", label: "Power Off", danger: true },
    ],
  },
  {
    id: "snapshotMenu",
    trigger: "Snapshots ▾",
    label: "Snapshot actions",
    needsVm: true,
    entries: [
      { action: "takeSnapshot", vmAction: "snapshot", icon: "snapshot", label: "Take Snapshot…" },
      { action: "openSnapshots", vmAction: "snapshot", icon: "grid", label: "Snapshot Manager…" },
    ],
  },
  {
    id: "devicesMenu",
    trigger: "Devices ▾",
    label: "Device actions",
    needsVm: true,
    entries: [
      { action: "changeCd", vmAction: "settings", icon: "disc", label: "Change CD/DVD ISO…" },
      { action: "ejectCd", vmAction: "settings", icon: "eject", label: "Eject CD/DVD" },
      "separator",
      { action: "sendCad", vmAction: "cad", icon: "keyboard", label: "Send Ctrl+Alt+Del" },
      { action: "reconnectDisplay", vmAction: "display", icon: "refresh", label: "Reconnect Display" },
      { action: "enterDisplayOnly", vmAction: "display", icon: "maximize", label: "Display Only" },
      { action: "manualDisconnectSerial", vmAction: "serial", icon: "terminal", label: "Disconnect Serial" },
    ],
  },
  {
    id: "toolsMenu",
    trigger: "Tools ▾",
    label: "Tools",
    needsVm: false,
    entries: [
      { action: "renameGuest", vmAction: "rename", icon: "edit", label: "Rename…" },
      { action: "moveToFolder", vmAction: "rename", icon: "folder", label: "Move to Folder…" },
      { action: "cloneGuest", vmAction: "clone", icon: "copy", label: "Clone…" },
      { action: "migrateGuest", vmAction: "migrate", icon: "migrate", label: "Migrate…" },
      { action: "exportOvf", vmAction: "export", icon: "export", label: "Export to OVF" },
      { action: "importGuest", icon: "import", label: "Import VM…" },
      "separator",
      { action: "openCatalog", icon: "grid", label: "VM Catalog…" },
      { action: "openVnets", icon: "net", label: "Virtual Network Editor…" },
      { action: "openPrefs", icon: "gear", label: "Preferences…" },
      { action: "showShortcutsModal", icon: "keyboard", label: "Keyboard Shortcuts" },
      { action: "openAbout", icon: "info", label: "About Hangar" },
    ],
  },
  {
    id: "dangerMenu",
    trigger: "Manage ▾",
    label: "Advanced actions",
    needsVm: false,
    danger: true,
    entries: [
      { action: "batchStart", vmAction: "batch-start", icon: "play", label: "Power On All Stopped" },
      { action: "batchStop", vmAction: "batch-stop", icon: "stop", label: "Power Off All Running", danger: true },
      "separator",
      { action: "deleteVm", vmAction: "delete", icon: "trash", label: "Delete VM", danger: true },
    ],
  },
];

export type ToolbarProps = {
  /** Whether the sidebar is open (mobile overlay) or not collapsed (desktop). */
  readonly sidebarExpanded: boolean;
  readonly hasVm: boolean;
  /** The selected VM is running or paused, so the power button turns it off. */
  readonly powered: boolean;
  /** Why `vmAction` is unavailable for the selected VM, or null when it is available. */
  readonly actionReason: (vmAction: VmAction) => string | null;
  /** A batch power run is going: its menu entry is off and reads `...`. */
  readonly batchBusy: "batchStart" | "batchStop" | null;
  readonly handlers: ToolbarHandlers;
};

export type ToolbarHandlers = {
  readonly toggleSidebar: () => void;
  readonly deselectVm: () => void;
  readonly powerToggle: () => void;
  readonly newVm: () => void;
  readonly editVm: () => void;
  readonly cycleTheme: () => void;
  readonly menu: Readonly<Record<MenuAction, () => void>>;
};

type OpenKind = "more" | MenuId;
type Open = { readonly kind: OpenKind; readonly anchor: HTMLElement } | null;

/** Lets code outside the tree (the Escape handler, VM selection) close the menus. */
export const toolbarControl = {
  /** Closes any open menu; returns whether one was open. */
  close: (_returnFocus: boolean): boolean => false,
};

const NO_VM_REASON = "Select a VM first";
const ICON = "ico size-3.25";
const WIDE_ICON = "ico size-3.75";
/** Direct toolbar buttons that collapse into the More popover below the compact breakpoint. */
const COLLAPSING = "max-compact:hidden";
const PHONE_BUTTON = "max-phone:px-2";
/** Elements whose clicks never count as "outside" the open menu. */
const MENU_PARTS = ".action-menu, .toolbar-more-popover, [data-menu], .toolbar-more";

const variantOf = (danger: boolean | undefined) => (danger === true ? "danger" : "default");

/** Calls `onOutside` for clicks outside the menu parts; returns the unsubscribe function. */
const listenOutsideClicks = (onOutside: () => void): (() => void) => {
  const controller = new AbortController();
  document.addEventListener(
    "click",
    (event) => {
      if (event.target instanceof Element && event.target.closest(MENU_PARTS) === null) {
        onOutside();
      }
    },
    { signal: controller.signal },
  );
  return () => controller.abort();
};

type MenuState = {
  readonly open: Open;
  readonly isOpen: (kind: OpenKind) => boolean;
  readonly toggle: (kind: OpenKind, anchor: HTMLElement) => void;
  /** Opens a menu from a More popover row, anchored where the popover was. */
  readonly openFromMore: (id: MenuId) => void;
  readonly close: () => void;
};

const useMenuState = (): MenuState => {
  const [open, setOpen] = useState<Open>(null);
  const openRef = useRef<Open>(null);
  openRef.current = open;
  const close = () => setOpen(null);

  useEffect(() => {
    toolbarControl.close = (returnFocus) => {
      const { current } = openRef;
      if (current === null) {
        return false;
      }
      setOpen(null);
      if (returnFocus) {
        current.anchor.focus();
      }
      return true;
    };
    return () => {
      toolbarControl.close = () => false;
    };
  }, []);

  useEffect(() => {
    if (open === null) {
      return undefined;
    }
    return listenOutsideClicks(() => setOpen(null));
  }, [open]);

  return {
    open,
    isOpen: (kind) => open?.kind === kind,
    toggle: (kind, anchor) => setOpen((current) => (current?.kind === kind ? null : { kind, anchor })),
    openFromMore: (id) => setOpen((current) => (current === null ? null : { kind: id, anchor: current.anchor })),
    close,
  };
};

const ToolbarButtons = ({ sidebarExpanded, hasVm, powered, actionReason, handlers }: ToolbarProps) => {
  let powerLabel = "Power On";
  let powerTitle = "Power on selected VM";
  if (!hasVm) {
    powerTitle = NO_VM_REASON;
  } else if (powered) {
    powerLabel = "Power Off";
    powerTitle = "Hard power off selected VM";
  }
  const settingsReason = actionReason("settings");
  return (
    <>
      <Button
        variant="ghost"
        class={cn("hamburger border-0 px-2 py-0.75 pointer-coarse:min-w-11", PHONE_BUTTON)}
        onClick={handlers.toggleSidebar}
        aria-label={sidebarExpanded ? "Collapse VM Library" : "Expand VM Library"}
        aria-controls="sidebar"
        aria-expanded={sidebarExpanded}
      >
        <Icon name="menu" class={WIDE_ICON} />
      </Button>
      <Button class={PHONE_BUTTON} data-action="deselectVm" onClick={handlers.deselectVm} title="Deselect VM (Ctrl+W)">
        <Icon name="home" class={ICON} />
        Home
      </Button>
      <Button
        id="powerbtn"
        variant={powered ? "danger" : "primary"}
        class={PHONE_BUTTON}
        onClick={handlers.powerToggle}
        title={powerTitle}
        disabled={!hasVm}
      >
        <Icon name="power" class={ICON} />
        {powerLabel}
      </Button>
      <Button variant="primary" class={cn("new-vm-btn", PHONE_BUTTON)} onClick={handlers.newVm} title="New VM">
        <Icon name="plus" class={ICON} />
        New VM
      </Button>
      <span class={cn("mx-1 my-1 w-px self-stretch bg-border", COLLAPSING)} aria-hidden="true" />
      <Button
        class={PHONE_BUTTON}
        data-action="editVm"
        onClick={handlers.editVm}
        data-vm-action="settings"
        title={settingsReason ?? "Settings"}
        disabled={settingsReason !== null}
        aria-disabled={settingsReason !== null}
      >
        <Icon name="gear" class={ICON} />
        Settings
      </Button>
    </>
  );
};

const triggerDisabled = (def: MenuDef, hasVm: boolean) => def.needsVm && !hasVm;

const MenuTriggers = ({ hasVm, state }: { readonly hasVm: boolean; readonly state: MenuState }) =>
  MENUS.map((def) => (
    <Button
      key={def.id}
      class={cn("menu-btn aria-expanded:border-border-hover aria-expanded:bg-surface-3 aria-expanded:text-fg", COLLAPSING)}
      data-menu={def.id}
      aria-haspopup="menu"
      aria-controls={def.id}
      aria-expanded={state.isOpen(def.id)}
      title={triggerDisabled(def, hasVm) ? NO_VM_REASON : undefined}
      disabled={triggerDisabled(def, hasVm)}
      onClick={(event) => state.toggle(def.id, event.currentTarget)}
    >
      {def.trigger}
    </Button>
  ));

/** Below the compact breakpoint the menu triggers live in this popover. */
const MorePopover = ({ hasVm, state }: { readonly hasVm: boolean; readonly state: MenuState }) => {
  const shown = state.isOpen("more");
  return (
    <Menu
      label="More actions"
      class="toolbar-more-popover z-200 min-w-48.75 max-w-62.5"
      open={shown}
      anchor={shown ? (state.open?.anchor ?? null) : null}
      align="end"
    >
      {shown &&
        MENUS.map((def) => (
          <MenuItem
            key={def.id}
            variant={variantOf(def.danger)}
            data-menu={def.id}
            aria-haspopup="menu"
            aria-controls={def.id}
            aria-expanded={false}
            disabled={triggerDisabled(def, hasVm)}
            title={triggerDisabled(def, hasVm) ? NO_VM_REASON : undefined}
            onClick={() => state.openFromMore(def.id)}
          >
            {def.trigger}
          </MenuItem>
        ))}
    </Menu>
  );
};

const ActionMenu = ({ def, state, actionReason, batchBusy, handlers }: {
  readonly def: MenuDef;
  readonly state: MenuState;
  readonly actionReason: ToolbarProps["actionReason"];
  readonly batchBusy: ToolbarProps["batchBusy"];
  readonly handlers: ToolbarHandlers["menu"];
}) => {
  const shown = state.isOpen(def.id);
  return (
    <Menu
      id={def.id}
      label={def.label}
      class="action-menu"
      open={shown}
      anchor={shown ? (state.open?.anchor ?? null) : null}
      onSelect={state.close}
    >
      {def.entries.map((entry, index) => {
        if (entry === "separator") {
          return <MenuSeparator key={`sep-${def.id}-${index}`} />;
        }
        const running = batchBusy === entry.action;
        const reason = entry.vmAction === undefined ? null : actionReason(entry.vmAction);
        return (
          <MenuItem
            key={`${entry.action}-${entry.vmAction ?? ""}`}
            variant={variantOf(entry.danger)}
            data-action={entry.action}
            data-vm-action={entry.vmAction}
            disabled={reason !== null || running}
            aria-disabled={reason !== null || running}
            title={reason ?? undefined}
            onClick={handlers[entry.action]}
          >
            <Icon name={entry.icon} class={menuIconClass(entry.danger === true)} />
            {running ? "..." : entry.label}
          </MenuItem>
        );
      })}
    </Menu>
  );
};

/** The VM toolbar: direct buttons, the five action menus, and the More popover for narrow widths. */
export const Toolbar = (props: ToolbarProps) => {
  const state = useMenuState();
  return (
    <div
      class="toolbar relative z-5 flex min-h-10 flex-wrap items-center gap-1 border-b border-border bg-bg-alt px-2.5 py-1.25 max-phone:gap-0.75 max-phone:px-1.5 displayonly:hidden"
      role="toolbar"
      aria-label="VM actions"
    >
      <ToolbarButtons {...props} />
      <MenuTriggers hasVm={props.hasVm} state={state} />
      <ThemeToggle onCycle={props.handlers.cycleTheme} />
      <Button
        class={cn("toolbar-more hidden max-compact:inline-flex", PHONE_BUTTON)}
        aria-label="More actions"
        aria-haspopup="menu"
        aria-expanded={state.isOpen("more")}
        onClick={(event) => state.toggle("more", event.currentTarget)}
      >
        <Icon name="more" class={WIDE_ICON} />
      </Button>
      <MorePopover hasVm={props.hasVm} state={state} />
      {MENUS.map((def) => (
        <ActionMenu
          key={def.id}
          def={def}
          state={state}
          actionReason={props.actionReason}
          batchBusy={props.batchBusy}
          handlers={props.handlers.menu}
        />
      ))}
    </div>
  );
};
