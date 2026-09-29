import { AboutDialog } from "@/components/dialogs/about";
import { ConfirmDialog, type ConfirmRequest } from "@/components/dialogs/confirm";
import { LogDialog, type LogState } from "@/components/dialogs/log";
import { PrefsDialog, type PrefsRequest } from "@/components/dialogs/prefs";
import { PromptDialog, type PromptRequest } from "@/components/dialogs/prompt";
import { ShortcutsDialog } from "@/components/dialogs/shortcuts";

/** Which dialogs are open. Each slot is null when closed. */
export type DialogsState = {
  readonly confirm: ConfirmRequest | null;
  readonly prompt: PromptRequest | null;
  /** The version line shown in About. */
  readonly about: { readonly version: string } | null;
  readonly shortcuts: true | null;
  readonly log: LogState | null;
  readonly prefs: PrefsRequest | null;
};

export type DialogsProps = DialogsState & {
  /** Called when a dialog has finished closing; `current` is the slot value that was open. */
  readonly onClose: (kind: keyof DialogsState, current: object | true) => void;
};

/** Mount point for every dialog ported to Preact; `#dialog-root` in index.html. */
export const Dialogs = ({ confirm, prompt, about, shortcuts, log, prefs, onClose }: DialogsProps) => (
  <>
    {prefs && <PrefsDialog request={prefs} onClose={() => onClose("prefs", prefs)} />}
    {about && <AboutDialog version={about.version} onClose={() => onClose("about", about)} />}
    {shortcuts && <ShortcutsDialog onClose={() => onClose("shortcuts", shortcuts)} />}
    {log && <LogDialog {...log} onClose={() => onClose("log", log)} />}
    {prompt && <PromptDialog request={prompt} onClose={() => onClose("prompt", prompt)} />}
    {confirm && <ConfirmDialog request={confirm} onClose={() => onClose("confirm", confirm)} />}
  </>
);
