import { render } from "preact";
import { Toolbar, toolbarControl, type ToolbarProps } from "@/components/toolbar";
import { VmList, type VmListProps } from "@/components/vm-list";

type HangarUi = {
  readonly renderVmList: (props: VmListProps) => void;
  /** Merges the given fields into the toolbar state and redraws it. */
  readonly setToolbar: (patch: Partial<ToolbarProps>) => void;
  /** Closes any open toolbar menu; returns whether one was open. */
  readonly closeToolbarMenus: (returnFocus: boolean) => boolean;
};

declare global {
  // Bridge for the legacy app.js, which computes state and hands it over for rendering.
  var hangarUi: HangarUi | undefined;
  var renderList: (() => void) | undefined;
  var syncToolbar: (() => void) | undefined;
  var syncSidebarButton: (() => void) | undefined;
}

const createBridge = (): HangarUi => {
  let toolbarProps: ToolbarProps = {
    sidebarExpanded: false,
    hasVm: false,
    powered: false,
    powerBusy: false,
    actionReason: () => null,
  };
  return {
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
