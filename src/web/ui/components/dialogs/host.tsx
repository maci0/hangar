import { AboutDialog } from "@/components/dialogs/about";
import { CatalogDialog, type CatalogState } from "@/components/dialogs/catalog";
import { CloneDialog, type CloneRequest } from "@/components/dialogs/clone";
import { ConfirmDialog, type ConfirmRequest } from "@/components/dialogs/confirm";
import { ImportDialog, type ImportRequest } from "@/components/dialogs/import";
import { LogDialog, type LogState } from "@/components/dialogs/log";
import { MigrateDialog, type MigrateRequest } from "@/components/dialogs/migrate";
import { NewVmDialog, type NewVmRequest } from "@/components/dialogs/new-vm";
import { PrefsDialog, type PrefsRequest } from "@/components/dialogs/prefs";
import { PromptDialog, type PromptRequest } from "@/components/dialogs/prompt";
import { ShortcutsDialog } from "@/components/dialogs/shortcuts";
import { SnapshotsDialog, type SnapshotsState } from "@/components/dialogs/snapshots";
import { TopologyDialog, type TopologyState } from "@/components/dialogs/topology";
import { VnetsDialog, type VnetsRequest } from "@/components/dialogs/vnets";

/** Which dialogs are open. Each slot is null when closed. */
export type DialogsState = {
  readonly confirm: ConfirmRequest | null;
  readonly prompt: PromptRequest | null;
  /** The version line shown in About. */
  readonly about: { readonly version: string } | null;
  readonly shortcuts: true | null;
  readonly log: LogState | null;
  readonly prefs: PrefsRequest | null;
  readonly newVm: NewVmRequest | null;
  readonly importVm: ImportRequest | null;
  readonly clone: CloneRequest | null;
  readonly snapshots: SnapshotsState | null;
  readonly migrate: MigrateRequest | null;
  readonly vnets: VnetsRequest | null;
  readonly topology: TopologyState | null;
  readonly catalog: CatalogState | null;
};

export type DialogsProps = DialogsState & {
  /** Called when a dialog has finished closing; `current` is the slot value that was open. */
  readonly onClose: (kind: keyof DialogsState, current: object | true) => void;
};

/** Mount point for every dialog ported to Preact; `#dialog-root` in index.html. */
export const Dialogs = ({
  confirm,
  prompt,
  about,
  shortcuts,
  log,
  prefs,
  newVm,
  importVm,
  clone,
  snapshots,
  migrate,
  vnets,
  topology,
  catalog,
  onClose,
}: DialogsProps) => (
  <>
    {newVm && <NewVmDialog request={newVm} onClose={() => onClose("newVm", newVm)} />}
    {importVm && <ImportDialog request={importVm} onClose={() => onClose("importVm", importVm)} />}
    {clone && <CloneDialog request={clone} onClose={() => onClose("clone", clone)} />}
    {snapshots && <SnapshotsDialog state={snapshots} onClose={() => onClose("snapshots", snapshots)} />}
    {migrate && <MigrateDialog request={migrate} onClose={() => onClose("migrate", migrate)} />}
    {vnets && <VnetsDialog request={vnets} onClose={() => onClose("vnets", vnets)} />}
    {topology && <TopologyDialog state={topology} onClose={() => onClose("topology", topology)} />}
    {catalog && <CatalogDialog state={catalog} onClose={() => onClose("catalog", catalog)} />}
    {prefs && <PrefsDialog request={prefs} onClose={() => onClose("prefs", prefs)} />}
    {about && <AboutDialog version={about.version} onClose={() => onClose("about", about)} />}
    {shortcuts && <ShortcutsDialog onClose={() => onClose("shortcuts", shortcuts)} />}
    {log && <LogDialog {...log} onClose={() => onClose("log", log)} />}
    {prompt && <PromptDialog request={prompt} onClose={() => onClose("prompt", prompt)} />}
    {confirm && <ConfirmDialog request={confirm} onClose={() => onClose("confirm", confirm)} />}
  </>
);
