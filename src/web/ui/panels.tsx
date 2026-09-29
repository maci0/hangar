import { render, type ComponentChild } from "preact";
import { Dashboard, type HostInfo } from "@/components/dashboard";
import { EmptyState } from "@/components/empty-state";
import { SettingsForm, settingsControl, type SettingsRequest } from "@/components/settings";
import { Summary, type SummaryProps } from "@/components/summary";
import { LibraryActions } from "@/components/library-actions";
import { DEFAULT_SORT, nextSort, type DashRow, type SortColumn, type SortState } from "@/lib/dashboard";
import { memText, statusLabel } from "@/lib/format";

/** What the Summary panel shows. `app.js` picks the view from the selection and the VM list. */
export type SummaryView =
  | { readonly kind: "welcome" }
  | { readonly kind: "dashboard"; readonly rows: ReadonlyArray<DashRow>; readonly host: HostInfo }
  | ({ readonly kind: "vm" } & SummaryProps);

export type PanelsBridge = {
  /** Draws the Summary panel: the welcome state, the host dashboard or the selected VM. */
  readonly setSummary: (view: SummaryView) => void;
  /** Opens the Settings form for a VM, replacing any form (its edits are dropped). */
  readonly openSettings: (request: SettingsRequest) => void;
  /** Replaces the Settings form with the no-VM-selected state. */
  readonly closeSettings: () => void;
  /** Submits the open Settings form, as its Save button does. */
  readonly saveSettings: () => void;
  /** Memory from exact MiB as a label (`512 MiB`, `1.5 GiB`). */
  readonly memText: (mib: number) => string;
  /** Display name of a VM status. */
  readonly statusLabel: (status: string) => string;
};

const mount = (selector: string, node: ComponentChild): void => {
  const root = document.querySelector(selector);
  if (root) {
    render(node, root);
  }
};

const Welcome = () => (
  <EmptyState icon="monitor" title="No Virtual Machines Yet" actions={<LibraryActions />}>
    Create your first virtual machine, import an existing disk image, or start from a catalog template.
  </EmptyState>
);

const NoSelection = () => (
  <EmptyState icon="gear" title="No Virtual Machine Selected">
    Select a VM from the sidebar to edit its settings.
  </EmptyState>
);

type SummaryPanelProps = { readonly view: SummaryView; readonly sort: SortState; readonly onSort: (col: SortColumn) => void };

const SummaryPanel = ({ view, sort, onSort }: SummaryPanelProps) => {
  if (view.kind === "dashboard") {
    return <Dashboard rows={view.rows} host={view.host} sort={sort} onSort={onSort} />;
  }
  if (view.kind === "vm") {
    return <Summary {...view} />;
  }
  return <Welcome />;
};

/** Summary and Settings panels. They mount into `#summary-root` and `#settings-root` inside their tab panels. */
export const createPanelsBridge = (): PanelsBridge => {
  let view: SummaryView = { kind: "welcome" };
  let sort: SortState = DEFAULT_SORT;
  let settings: { readonly id: number; readonly request: SettingsRequest } | null = null;
  let category = "";

  const drawSummary = (): void => {
    const onSort = (col: SortColumn): void => {
      sort = nextSort(sort, col);
      drawSummary();
    };
    mount("#summary-root", <SummaryPanel view={view} sort={sort} onSort={onSort} />);
  };

  const drawSettings = (): void => {
    const onCategory = (id: string): void => {
      category = id;
      drawSettings();
    };
    mount(
      "#settings-root",
      settings === null ? (
        <NoSelection />
      ) : (
        <SettingsForm key={settings.id} request={settings.request} category={category} onCategory={onCategory} />
      ),
    );
  };

  drawSummary();
  drawSettings();
  return {
    setSummary: (next) => {
      view = next;
      drawSummary();
    },
    openSettings: (request) => {
      settings = { id: (settings?.id ?? 0) + 1, request };
      drawSettings();
    },
    closeSettings: () => {
      settings = null;
      drawSettings();
    },
    saveSettings: () => settingsControl.submit(),
    memText,
    statusLabel,
  };
};
