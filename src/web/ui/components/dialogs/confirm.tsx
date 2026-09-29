import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, useDialogClose } from "@/components/ui/dialog";

export type ConfirmRequest = {
  readonly id: number;
  readonly message: string;
  /** Irreversible action: the confirm button is red. */
  readonly danger: boolean;
  readonly okLabel: string;
  /** Called with the answer; a later call is ignored, so Escape after OK stays true. */
  readonly resolve: (confirmed: boolean) => void;
};

const ConfirmContent = ({ request }: { readonly request: ConfirmRequest }) => {
  const close = useDialogClose();
  const confirm = () => {
    request.resolve(true);
    close();
  };
  return (
    <>
      <DialogBody class="text-center">
        <p id="confirmmsg" class="leading-relaxed whitespace-pre-line text-fg">
          {request.message}
        </p>
      </DialogBody>
      <DialogFooter class="justify-center border-t-0">
        <DialogClose id="confirmCancelBtn" onClick={() => request.resolve(false)}>
          Cancel
        </DialogClose>
        <Button id="confirmOkBtn" type="button" variant={request.danger ? "danger" : "primary"} onClick={confirm}>
          {request.okLabel}
        </Button>
      </DialogFooter>
    </>
  );
};

export type ConfirmDialogProps = {
  readonly request: ConfirmRequest;
  readonly onClose: () => void;
};

/** Yes/no question. Cancel is first in tab order, so it holds the initial focus. */
export const ConfirmDialog = ({ request, onClose }: ConfirmDialogProps) => (
  <Dialog
    key={request.id}
    id="confirmdlg"
    titleId="confirmmsg"
    onClose={() => {
      request.resolve(false);
      onClose();
    }}
  >
    <ConfirmContent request={request} />
  </Dialog>
);
