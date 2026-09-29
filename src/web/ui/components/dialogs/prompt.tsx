import { useEffect, useRef, useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogForm, useDialogClose } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";

const SUGGESTIONS_ID = "promptOptions";

export type PromptRequest = {
  readonly id: number;
  readonly label: string;
  readonly initial: string;
  /** Values offered by the browser's datalist while typing (folder names). */
  readonly suggestions: ReadonlyArray<string>;
  /** Called with the entered text, or null when cancelled; a later call is ignored. */
  readonly resolve: (value: string | null) => void;
};

const PromptContent = ({ request }: { readonly request: PromptRequest }) => {
  const close = useDialogClose();
  const input = useRef<HTMLInputElement>(null);
  const [value, setValue] = useState(request.initial);

  useEffect(() => {
    input.current?.select();
  }, []);

  const submit = (event: Event) => {
    event.preventDefault();
    request.resolve(value);
    close();
  };

  return (
    <DialogForm onSubmit={submit}>
      <DialogBody>
        <Field label={request.label} labelId="promptLabel" htmlFor="promptInput">
          <Input
            id="promptInput"
            ref={input}
            type="text"
            value={value}
            list={request.suggestions.length > 0 ? SUGGESTIONS_ID : undefined}
            onInput={(event) => setValue(event.currentTarget.value)}
          />
        </Field>
        <datalist id={SUGGESTIONS_ID}>
          {request.suggestions.map((option) => (
            <option key={option} value={option} />
          ))}
        </datalist>
      </DialogBody>
      <DialogFooter>
        <DialogClose id="promptCancelBtn" onClick={() => request.resolve(null)}>
          Cancel
        </DialogClose>
        <Button id="promptOkBtn" type="submit" variant="primary">
          OK
        </Button>
      </DialogFooter>
    </DialogForm>
  );
};

export type PromptDialogProps = {
  readonly request: PromptRequest;
  readonly onClose: () => void;
};

/** One-line text question, replacing `window.prompt`. Enter submits. */
export const PromptDialog = ({ request, onClose }: PromptDialogProps) => (
  <Dialog
    key={request.id}
    id="promptdlg"
    titleId="promptLabel"
    onClose={() => {
      request.resolve(null);
      onClose();
    }}
  >
    <PromptContent request={request} />
  </Dialog>
);
