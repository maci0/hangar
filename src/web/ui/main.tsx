import { render } from "preact";
import { Dialogs, type DialogsState } from "@/components/dialogs/host";
import type { CloneRequest } from "@/components/dialogs/clone";
import type { ImportRequest } from "@/components/dialogs/import";
import type { MigrateRequest } from "@/components/dialogs/migrate";
import type { NewVmRequest } from "@/components/dialogs/new-vm";
import type { PrefsRequest } from "@/components/dialogs/prefs";
import type { SnapshotsState } from "@/components/dialogs/snapshots";
import { Toolbar, toolbarControl, type ToolbarProps } from "@/components/toolbar";
import { VmList, type VmListProps } from "@/components/vm-list";

export type ConfirmOptions = {
  /** Irreversible action: the confirm button is red. */
  readonly danger?: boolean;
  /** Confirm button text; defaults to OK. */
  readonly okLabel?: string;
};

type HangarUi = {
  readonly renderVmList: (props: VmListProps) => void;
  /** Merges the given fields into the toolbar state and redraws it. */
  readonly setToolbar: (patch: Partial<ToolbarProps>) => void;
  /** Closes any open toolbar menu; returns whether one was open. */
  readonly closeToolbarMenus: (returnFocus: boolean) => boolean;
  /** Resolves true when the user confirms; false on Cancel, Escape or a backdrop click. */
  readonly confirm: (message: string, options?: ConfirmOptions) => Promise<boolean>;
  /** Resolves the entered text, or null when cancelled. */
  readonly prompt: (label: string, initial: string, suggestions: ReadonlyArray<string>) => Promise<string | null>;
  readonly openAbout: () => void;
  /** Fills the version line of About; ignored while it is closed. */
  readonly setAboutVersion: (version: string) => void;
  readonly openShortcuts: () => void;
  readonly openLog: (vmName: string) => void;
  /** Replaces the log text of the open QEMU log; ignored while it is closed. */
  readonly setLog: (text: string) => void;
  readonly openPrefs: (request: PrefsRequest) => void;
  readonly openNewVm: (request: NewVmRequest) => void;
  readonly openImport: (request: ImportRequest) => void;
  readonly openClone: (request: CloneRequest) => void;
  readonly openMigrate: (request: MigrateRequest) => void;
  /** Opens the Snapshot Manager; the list starts as loading until `setSnapshots` pushes it. */
  readonly openSnapshots: (state: SnapshotsState) => void;
  /** Merges the fields into the open Snapshot Manager; ignored while it is closed. */
  readonly setSnapshots: (patch: Partial<SnapshotsState>) => void;
};

declare global {
  // Bridge for the legacy app.js, which computes state and hands it over for rendering.
  var hangarUi: HangarUi | undefined;
  var renderList: (() => void) | undefined;
  var syncToolbar: (() => void) | undefined;
  var syncSidebarButton: (() => void) | undefined;
}

const CLOSED_DIALOGS: DialogsState = {
  confirm: null,
  prompt: null,
  about: null,
  shortcuts: null,
  log: null,
  prefs: null,
  newVm: null,
  importVm: null,
  clone: null,
  snapshots: null,
  migrate: null,
};

type DialogBridge = Omit<HangarUi, "renderVmList" | "setToolbar" | "closeToolbarMenus">;

/** Dialog state lives here; `#dialog-root` is redrawn from it after every change. */
type DialogStore = {
  readonly get: () => DialogsState;
  readonly set: (patch: Partial<DialogsState>) => void;
};

const createDialogStore = (): DialogStore => {
  let dialogs = CLOSED_DIALOGS;
  const set = (patch: Partial<DialogsState>): void => {
    dialogs = { ...dialogs, ...patch };
    const root = document.querySelector("#dialog-root");
    if (root) {
      render(
        <Dialogs
          {...dialogs}
          onClose={(kind, current) => {
            // Clears the slot only if it still holds the dialog that closed, not a newer one.
            if (dialogs[kind] === current) {
              set({ [kind]: null });
            }
          }}
        />,
        root,
      );
    }
  };
  return { get: () => dialogs, set };
};

const createAnswerDialogs = ({ get, set }: DialogStore): Pick<DialogBridge, "confirm" | "prompt"> => {
  let requestId = 0;
  const nextId = (): number => {
    requestId += 1;
    return requestId;
  };
  return {
    confirm: (message, options) => {
      const { promise, resolve } = Promise.withResolvers<boolean>();
      get().confirm?.resolve(false);
      set({
        confirm: { id: nextId(), message, danger: options?.danger ?? false, okLabel: options?.okLabel ?? "OK", resolve },
      });
      return promise;
    },
    prompt: (label, initial, suggestions) => {
      const { promise, resolve } = Promise.withResolvers<string | null>();
      get().prompt?.resolve(null);
      set({ prompt: { id: nextId(), label, initial, suggestions, resolve } });
      return promise;
    },
  };
};

const createInfoDialogs = ({ get, set }: DialogStore) => ({
  openAbout: () => set({ about: get().about ?? { version: "" } }),
  setAboutVersion: (version: string) => {
    if (get().about) {
      set({ about: { version } });
    }
  },
  openShortcuts: () => set({ shortcuts: true }),
  openLog: (vmName: string) => set({ log: { vmName, text: "Loading…" } }),
  setLog: (text: string) => {
    const { log } = get();
    if (log) {
      set({ log: { ...log, text } });
    }
  },
  openPrefs: (request: PrefsRequest) => set({ prefs: get().prefs ?? request }),
});

const createVmDialogs = ({ get, set }: DialogStore) => ({
  openNewVm: (request: NewVmRequest) => set({ newVm: get().newVm ?? request }),
  openImport: (request: ImportRequest) => set({ importVm: get().importVm ?? request }),
  openClone: (request: CloneRequest) => set({ clone: get().clone ?? request }),
  openMigrate: (request: MigrateRequest) => set({ migrate: get().migrate ?? request }),
  openSnapshots: (state: SnapshotsState) => set({ snapshots: get().snapshots ?? state }),
  setSnapshots: (patch: Partial<SnapshotsState>) => {
    const { snapshots } = get();
    if (snapshots) {
      set({ snapshots: { ...snapshots, ...patch } });
    }
  },
});

const createDialogBridge = (): DialogBridge => {
  const store = createDialogStore();
  return { ...createAnswerDialogs(store), ...createInfoDialogs(store), ...createVmDialogs(store) };
};

const createBridge = (): HangarUi => {
  let toolbarProps: ToolbarProps = {
    sidebarExpanded: false,
    hasVm: false,
    powered: false,
    powerBusy: false,
    actionReason: () => null,
  };
  return {
    ...createDialogBridge(),
    renderVmList: (props) => {
      const list = document.querySelector("#vmlist");
      if (list) {
        render(<VmList {...props} />, list);
      }
    },
    setToolbar: (patch) => {
      toolbarProps = { ...toolbarProps, ...patch };
      const root = document.querySelector("#toolbar-root");
      if (root) {
        render(<Toolbar {...toolbarProps} />, root);
      }
    },
    closeToolbarMenus: (returnFocus) => toolbarControl.close(returnFocus),
  };
};

globalThis.hangarUi = createBridge();
// State pushed before this bundle loaded was skipped; draw it now.
globalThis.renderList?.();
globalThis.syncToolbar?.();
globalThis.syncSidebarButton?.();
