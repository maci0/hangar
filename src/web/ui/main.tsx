import { render } from "preact";
import { Dialogs, type DialogsState } from "@/components/dialogs/host";
import type { PrefsRequest } from "@/components/dialogs/prefs";
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
};

declare global {
  // Bridge for the legacy app.js, which computes state and hands it over for rendering.
  var hangarUi: HangarUi | undefined;
  var renderList: (() => void) | undefined;
  var syncToolbar: (() => void) | undefined;
  var syncSidebarButton: (() => void) | undefined;
}

const CLOSED_DIALOGS: DialogsState = { confirm: null, prompt: null, about: null, shortcuts: null, log: null, prefs: null };

type DialogBridge = Pick<
  HangarUi,
  | "confirm"
  | "prompt"
  | "openAbout"
  | "setAboutVersion"
  | "openShortcuts"
  | "openLog"
  | "setLog"
  | "openPrefs"
>;

/** Dialog state lives here; `#dialog-root` is redrawn from it after every change. */
const createDialogBridge = (): DialogBridge => {
  let dialogs = CLOSED_DIALOGS;
  let requestId = 0;
  const nextId = (): number => {
    requestId += 1;
    return requestId;
  };

  const setDialogs = (patch: Partial<DialogsState>): void => {
    dialogs = { ...dialogs, ...patch };
    const root = document.querySelector("#dialog-root");
    if (root) {
      render(
        <Dialogs
          {...dialogs}
          onClose={(kind, current) => {
            // Clears the slot only if it still holds the dialog that closed, not a newer one.
            if (dialogs[kind] === current) {
              setDialogs({ [kind]: null });
            }
          }}
        />,
        root,
      );
    }
  };

  return {
    confirm: (message, options) => {
      const { promise, resolve } = Promise.withResolvers<boolean>();
      dialogs.confirm?.resolve(false);
      setDialogs({
        confirm: { id: nextId(), message, danger: options?.danger ?? false, okLabel: options?.okLabel ?? "OK", resolve },
      });
      return promise;
    },
    prompt: (label, initial, suggestions) => {
      const { promise, resolve } = Promise.withResolvers<string | null>();
      dialogs.prompt?.resolve(null);
      setDialogs({ prompt: { id: nextId(), label, initial, suggestions, resolve } });
      return promise;
    },
    openAbout: () => setDialogs({ about: dialogs.about ?? { version: "" } }),
    setAboutVersion: (version) => {
      if (dialogs.about) {
        setDialogs({ about: { version } });
      }
    },
    openShortcuts: () => setDialogs({ shortcuts: true }),
    openLog: (vmName) => setDialogs({ log: { vmName, text: "Loading…" } }),
    setLog: (text) => {
      if (dialogs.log) {
        setDialogs({ log: { ...dialogs.log, text } });
      }
    },
    openPrefs: (request) => setDialogs({ prefs: dialogs.prefs ?? request }),
  };
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
