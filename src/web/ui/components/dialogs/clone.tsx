import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle, useDialogTask } from "@/components/ui/dialog";

export type CloneRequest = {
  readonly vmName: string;
  /** Clones the VM; resolves whether it was cloned (then the dialog closes). */
  readonly clone: (linked: boolean) => Promise<boolean>;
};

const CloneContent = ({ request }: { readonly request: CloneRequest }) => {
  const { busy, run } = useDialogTask();
  return (
    <>
      <DialogBody>
        <p>
          Clone <strong id="clone_name">{request.vmName}</strong>?
        </p>
      </DialogBody>
      <DialogFooter>
        <DialogClose>Cancel</DialogClose>
        <Button type="button" disabled={busy} onClick={() => run(() => request.clone(false))}>
          Full Clone
        </Button>
        <Button type="button" variant="primary" disabled={busy} onClick={() => run(() => request.clone(true))}>
          Linked Clone
        </Button>
      </DialogFooter>
    </>
  );
};

export type CloneDialogProps = {
  readonly request: CloneRequest;
  readonly onClose: () => void;
};

export const CloneDialog = ({ request, onClose }: CloneDialogProps) => (
  <Dialog id="clonedlg" titleId="clone-title" onClose={onClose}>
    <DialogTitle id="clone-title">Clone Virtual Machine</DialogTitle>
    <CloneContent request={request} />
  </Dialog>
);
