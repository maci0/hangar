import { useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogForm, DialogTitle, useDialogTask } from "@/components/ui/dialog";
import { focusFirstInvalid, InputField } from "@/components/ui/field";
import { LabelHint, RequiredMark } from "@/components/ui/label";

const NAME_MAX_LENGTH = 80;
const DISK_IMAGE_PATTERN = /\.(?:qcow2|qcow|vmdk|vdi|vhdx|raw|img)$/i;

export type ImportRequest = {
  /** Imports the disk image; resolves whether it was imported (then the dialog closes). `name` is empty for the file name. */
  readonly importVm: (path: string, name: string) => Promise<boolean>;
};

/** Returns the problem with `path`, or an empty string. */
const validatePath = (path: string): string => {
  if (path === "") {
    return "A file path is required.";
  }
  if (path.includes("..")) {
    return "Parent directory traversal is not allowed.";
  }
  return DISK_IMAGE_PATTERN.test(path) ? "" : "Path must end with a disk image extension (.qcow2, .vmdk, .vdi, .vhdx, .raw, .img).";
};

type ImportFieldsProps = {
  readonly path: string;
  readonly name: string;
  readonly error: string;
  readonly onPath: (path: string) => void;
  readonly onName: (name: string) => void;
};

const ImportFields = ({ path, name, error, onPath, onName }: ImportFieldsProps) => (
  <>
    <p class="text-xs text-fg-muted">Imports an existing disk image as a new VM. The image is used in place; it is not copied.</p>
    <div class="grid gap-1">
      <InputField
        id="imp_path"
        label={
          <>
            Disk Image Path <RequiredMark />
          </>
        }
        type="text"
        required
        placeholder="/var/lib/images/guest.qcow2"
        value={path}
        error={error}
        onInput={(event) => onPath(event.currentTarget.value)}
      />
      <p class="text-caption text-fg-muted">Supported: .qcow2, .qcow, .vmdk, .vdi, .vhdx, .raw, .img</p>
    </div>
    <InputField
      id="imp_name"
      label={
        <>
          VM Name <LabelHint>(optional, defaults to the file name)</LabelHint>
        </>
      }
      type="text"
      maxLength={NAME_MAX_LENGTH}
      value={name}
      onInput={(event) => onName(event.currentTarget.value)}
    />
  </>
);

const ImportForm = ({ request }: { readonly request: ImportRequest }) => {
  const { busy, run } = useDialogTask();
  const [path, setPath] = useState("");
  const [name, setName] = useState("");
  const [error, setError] = useState("");

  const submit = () => {
    const trimmed = path.trim();
    setError(validatePath(trimmed));
    if (validatePath(trimmed) !== "") {
      focusFirstInvalid("importdlg");
      return;
    }
    run(() => request.importVm(trimmed, name.trim()));
  };

  return (
    <DialogForm
      noValidate
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <DialogBody class="grid gap-3">
        <ImportFields
          path={path}
          name={name}
          error={error}
          onPath={(value) => {
            setPath(value);
            setError("");
          }}
          onName={setName}
        />
      </DialogBody>
      <DialogFooter>
        <DialogClose>Cancel</DialogClose>
        <Button type="submit" variant="primary" disabled={busy}>
          Import
        </Button>
      </DialogFooter>
    </DialogForm>
  );
};

export type ImportDialogProps = {
  readonly request: ImportRequest;
  readonly onClose: () => void;
};

/** Import an existing disk image as a VM. Enter submits. */
export const ImportDialog = ({ request, onClose }: ImportDialogProps) => (
  <Dialog id="importdlg" titleId="import-title" onClose={onClose}>
    <DialogTitle id="import-title">Import Virtual Machine</DialogTitle>
    <ImportForm request={request} />
  </Dialog>
);
