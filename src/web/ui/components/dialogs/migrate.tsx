import { useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogForm, DialogTitle, useDialogTask } from "@/components/ui/dialog";
import { focusFirstInvalid, InputField } from "@/components/ui/field";
import { LabelHint, RequiredMark } from "@/components/ui/label";

const PORT_MIN = 1;
const PORT_MAX = 65_535;

export type MigrateRequest = {
  readonly vmName: string;
  /** Starts the migration; resolves whether it started (then the dialog closes). The page shows the progress. */
  readonly start: (host: string, port: number) => Promise<boolean>;
};

type Errors = { readonly host?: string; readonly port?: string };

const validate = (host: string, port: string): Errors => {
  const portNumber = Number.parseInt(port, 10);
  return {
    host: host === "" ? "Target host is required." : undefined,
    port: portNumber >= PORT_MIN && portNumber <= PORT_MAX ? undefined : `Port must be ${PORT_MIN}-${PORT_MAX}.`,
  };
};

type MigrateFieldsProps = {
  readonly host: string;
  readonly port: string;
  readonly errors: Errors;
  readonly onHost: (host: string) => void;
  readonly onPort: (port: string) => void;
};

const MigrateFields = ({ host, port, errors, onHost, onPort }: MigrateFieldsProps) => (
  <>
    <InputField
      id="mig_host"
      label={
        <>
          Target Host <RequiredMark />
        </>
      }
      type="text"
      required
      placeholder="hostname or IP"
      value={host}
      error={errors.host}
      onInput={(event) => onHost(event.currentTarget.value)}
    />
    <InputField
      id="mig_port"
      label="Target Port"
      type="number"
      min={PORT_MIN}
      max={PORT_MAX}
      value={port}
      error={errors.port}
      onInput={(event) => onPort(event.currentTarget.value)}
    />
    <InputField
      id="mig_uri"
      label={
        <>
          Migration URI <LabelHint>(read-only, built from host and port above)</LabelHint>
        </>
      }
      type="text"
      readOnly
      placeholder="tcp:host:port"
      value={host.trim() === "" ? "" : `tcp:${host.trim()}:${port}`}
    />
  </>
);

const MigrateForm = ({ request }: { readonly request: MigrateRequest }) => {
  const { busy, run } = useDialogTask();
  const [host, setHost] = useState("");
  const [port, setPort] = useState("4444");
  const [showErrors, setShowErrors] = useState(false);
  const target = host.trim();
  const errors = showErrors ? validate(target, port) : {};

  const submit = () => {
    setShowErrors(true);
    const found = validate(target, port);
    if (found.host !== undefined || found.port !== undefined) {
      focusFirstInvalid("migratedlg");
      return;
    }
    run(() => request.start(target, Number.parseInt(port, 10)));
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
        <p id="migrate_vmname" class="font-semibold">
          {request.vmName}
        </p>
        <MigrateFields host={host} port={port} errors={errors} onHost={setHost} onPort={setPort} />
      </DialogBody>
      <DialogFooter>
        <DialogClose>Cancel</DialogClose>
        <Button type="submit" variant="primary" disabled={busy}>
          Migrate
        </Button>
      </DialogFooter>
    </DialogForm>
  );
};

export type MigrateDialogProps = {
  readonly request: MigrateRequest;
  readonly onClose: () => void;
};

export const MigrateDialog = ({ request, onClose }: MigrateDialogProps) => (
  <Dialog id="migratedlg" titleId="migrate-title" onClose={onClose}>
    <DialogTitle id="migrate-title">Migrate Virtual Machine</DialogTitle>
    <MigrateForm request={request} />
  </Dialog>
);
