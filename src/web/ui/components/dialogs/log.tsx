import { useEffect, useRef } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle } from "@/components/ui/dialog";

export type LogState = {
  readonly vmName: string;
  /** Log text, or a status line while loading or when there is none. */
  readonly text: string;
};

export type LogDialogProps = LogState & {
  readonly onClose: () => void;
};

/** QEMU log viewer. app.js fetches the log and pushes `text`; Refresh asks it to fetch again. */
export const LogDialog = ({ vmName, text, onClose }: LogDialogProps) => {
  const body = useRef<HTMLPreElement>(null);

  // Newest output is at the end.
  useEffect(() => {
    if (body.current) {
      body.current.scrollTop = body.current.scrollHeight;
    }
  }, [text]);

  return (
    <Dialog id="logdlg" titleId="log-title" onClose={onClose}>
      <DialogTitle id="log-title">
        QEMU Log, <span id="log_vmname">{vmName}</span>
      </DialogTitle>
      <DialogBody>
        <pre
          id="logbody"
          ref={body}
          tabIndex={0}
          role="region"
          aria-label="QEMU log output"
          class="max-h-96 overflow-auto rounded-md border border-border bg-bg p-3 font-mono text-xs break-words whitespace-pre-wrap text-fg -outline-offset-2 outline-accent focus-visible:outline-2"
        >
          {text}
        </pre>
      </DialogBody>
      <DialogFooter>
        <Button type="button" data-action="refreshLog">
          Refresh
        </Button>
        <DialogClose>Close</DialogClose>
      </DialogFooter>
    </Dialog>
  );
};
