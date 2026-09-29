import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle } from "@/components/ui/dialog";

export type AboutDialogProps = {
  /** Shown under the tagline; empty until the daemon reports it. */
  readonly version: string;
  readonly onClose: () => void;
};

export const AboutDialog = ({ version, onClose }: AboutDialogProps) => (
  <Dialog id="aboutdlg" titleId="about-title" onClose={onClose}>
    <DialogTitle id="about-title">About Hangar</DialogTitle>
    <DialogBody class="text-center">
      <div
        aria-hidden="true"
        class="mb-3 inline-flex size-12 items-center justify-center rounded-lg bg-accent text-2xl font-bold text-on-accent"
      >
        H
      </div>
      <p class="text-title font-semibold">Hangar VM Manager</p>
      <p class="mt-1 text-field text-fg-muted">Lightweight QEMU VM manager</p>
      <p class="mt-2 text-xs text-fg-dim">Zig + QEMU + noVNC/SPICE web UI</p>
      <p id="aboutVersion" class="mt-2 min-h-4 text-caption text-fg-muted">
        {version}
      </p>
    </DialogBody>
    <DialogFooter>
      <DialogClose>Close</DialogClose>
    </DialogFooter>
  </Dialog>
);
