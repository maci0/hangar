import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle } from "@/components/ui/dialog";

type Shortcut = {
  /** Alternatives that trigger the same action. */
  readonly keys: ReadonlyArray<string>;
  readonly action: string;
};

const SHORTCUTS: ReadonlyArray<Shortcut> = [
  { keys: ["↑↓"], action: "Navigate VM list" },
  { keys: ["Enter"], action: "Power On/Off selected VM" },
  { keys: ["Delete"], action: "Delete selected VM" },
  { keys: ["Esc"], action: "Close dialog / Deselect VM" },
  { keys: ["F5"], action: "Refresh VM list" },
  { keys: ["F11"], action: "Fullscreen / Display-only mode" },
  { keys: ["Ctrl+F"], action: "Focus search" },
  { keys: ["Ctrl+K"], action: "Command palette (run a command or jump to a VM)" },
  { keys: ["Ctrl+S"], action: "Save settings (Settings tab) · Suspend VM otherwise" },
  { keys: ["Ctrl+Enter"], action: "Edit VM settings" },
  { keys: ["Alt+↑↓"], action: "Reorder VM in list" },
  { keys: ["←→"], action: "Switch between VM tabs" },
  { keys: ["Ctrl+N"], action: "New VM" },
  { keys: ["Ctrl+Shift+N"], action: "Clone VM" },
  { keys: ["Ctrl+E", "F2"], action: "Edit VM settings" },
  { keys: ["Ctrl+I"], action: "Import VM" },
  { keys: ["Ctrl+P"], action: "Open Preferences" },
  { keys: ["Ctrl+W"], action: "Home (deselect VM)" },
  { keys: ["?"], action: "Show this shortcuts list" },
];

export type ShortcutsDialogProps = {
  readonly onClose: () => void;
};

export const ShortcutsDialog = ({ onClose }: ShortcutsDialogProps) => (
  <Dialog id="shortcutsdlg" titleId="shortcuts-title" onClose={onClose}>
    <DialogTitle id="shortcuts-title">Keyboard Shortcuts</DialogTitle>
    <DialogBody>
      <table class="w-full border-collapse text-field">
        <tbody>
          {SHORTCUTS.map(({ keys, action }) => (
            <tr key={keys.join("/")}>
              <th scope="row" class="py-1 pr-3 text-left font-normal whitespace-nowrap text-fg-muted">
                {keys.map((key, index) => (
                  <>
                    {index > 0 && " / "}
                    <kbd>{key}</kbd>
                  </>
                ))}
              </th>
              <td class="py-1">{action}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </DialogBody>
    <DialogFooter>
      <DialogClose>Close</DialogClose>
    </DialogFooter>
  </Dialog>
);
