import { useEffect, useRef, useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogForm, DialogTitle, useDialogTask } from "@/components/ui/dialog";
import { Field, focusFirstInvalid, InputField } from "@/components/ui/field";
import { LabelHint, RequiredMark } from "@/components/ui/label";
import { Select } from "@/components/ui/select";

const NAME_MAX_LENGTH = 80;
const MEMORY_MIN_MB = 128;
const MEMORY_MAX_MB = 65_536;
const CPU_MIN = 1;
const CPU_MAX = 256;
const DISK_MIN_GB = 1;
const DISK_MAX_GB = 65_536;

/** Index is the daemon's `guest_os` value. */
const GUEST_OS_LABELS = ["Linux", "Windows", "FreeBSD", "macOS", "Other"];

/** What the daemon receives; numbers are already validated. */
export type NewVmValues = {
  readonly name: string;
  readonly memoryMb: number;
  readonly cpuCores: number;
  readonly diskGb: number;
  readonly guestOs: string;
  readonly isoPath: string;
  readonly firmware: string;
};

export type NewVmRequest = {
  /** Creates the VM; resolves whether it was created (then the dialog closes). */
  readonly create: (values: NewVmValues) => Promise<boolean>;
};

/** Everything as typed. */
type Form = {
  readonly name: string;
  readonly memoryMb: string;
  readonly cpuCores: string;
  readonly diskGb: string;
  readonly guestOs: string;
  readonly isoPath: string;
  readonly firmware: string;
};

type Errors = Partial<Record<"name" | "memoryMb" | "cpuCores" | "diskGb", string>>;

const INITIAL_FORM: Form = {
  name: "",
  memoryMb: "2048",
  cpuCores: "2",
  diskGb: "20",
  guestOs: "0",
  isoPath: "",
  firmware: "bios",
};

/** Editing one of these reveals the validation messages; the rest have no rules. */
const VALIDATED: ReadonlySet<keyof Form> = new Set(["name", "memoryMb", "cpuCores", "diskGb"]);

const outOfRange = (text: string, min: number, max: number): boolean => {
  const value = Number.parseInt(text, 10);
  return !(value >= min && value <= max);
};

const validate = (form: Form): Errors => ({
  name: form.name.trim() === "" ? "Name is required." : undefined,
  memoryMb: outOfRange(form.memoryMb, MEMORY_MIN_MB, MEMORY_MAX_MB) ? `Memory must be ${MEMORY_MIN_MB}-${MEMORY_MAX_MB} MB.` : undefined,
  cpuCores: outOfRange(form.cpuCores, CPU_MIN, CPU_MAX) ? `CPU cores must be ${CPU_MIN}-${CPU_MAX}.` : undefined,
  diskGb: outOfRange(form.diskGb, DISK_MIN_GB, DISK_MAX_GB) ? `Disk size must be ${DISK_MIN_GB}-${DISK_MAX_GB} GB.` : undefined,
});

const hasErrors = (errors: Errors): boolean =>
  errors.name !== undefined || errors.memoryMb !== undefined || errors.cpuCores !== undefined || errors.diskGb !== undefined;

type ValueEvent = Event & { readonly currentTarget: { readonly value: string } };

type Bind = (key: keyof Form) => { readonly value: string; readonly onInput: (event: ValueEvent) => void };

type FieldsProps = {
  readonly errors: Errors;
  readonly bind: Bind;
};

const SizeFields = ({ errors, bind }: FieldsProps) => (
  <>
    <InputField id="n_mem" label="Memory (MB)" type="number" min={MEMORY_MIN_MB} max={MEMORY_MAX_MB} step={1} error={errors.memoryMb} {...bind("memoryMb")} />
    <InputField id="n_cpu" label="CPU Cores" type="number" min={CPU_MIN} max={CPU_MAX} step={1} error={errors.cpuCores} {...bind("cpuCores")} />
    <InputField id="n_disk" label="Disk Size (GB)" type="number" min={DISK_MIN_GB} max={DISK_MAX_GB} step={1} error={errors.diskGb} {...bind("diskGb")} />
  </>
);

const SystemFields = ({ bind }: Pick<FieldsProps, "bind">) => (
  <>
    <Field label="Guest OS" htmlFor="n_guest_os">
      <Select id="n_guest_os" {...bind("guestOs")}>
        {GUEST_OS_LABELS.map((label, index) => (
          <option key={label} value={String(index)}>
            {label}
          </option>
        ))}
      </Select>
    </Field>
    <InputField
      id="n_iso"
      label={
        <>
          Installer ISO Path <LabelHint>(optional)</LabelHint>
        </>
      }
      type="text"
      placeholder="/path/to/installer.iso"
      {...bind("isoPath")}
    />
    <Field label="Firmware" htmlFor="n_firmware">
      <Select id="n_firmware" {...bind("firmware")}>
        <option value="bios">BIOS</option>
        <option value="uefi">UEFI</option>
      </Select>
    </Field>
  </>
);

const toValues = (form: Form): NewVmValues => ({
  name: form.name.trim(),
  memoryMb: Number.parseInt(form.memoryMb, 10),
  cpuCores: Number.parseInt(form.cpuCores, 10),
  diskGb: Number.parseInt(form.diskGb, 10),
  guestOs: form.guestOs,
  isoPath: form.isoPath.trim(),
  firmware: form.firmware,
});

const NewVmForm = ({ request }: { readonly request: NewVmRequest }) => {
  const { busy, run } = useDialogTask();
  const [form, setForm] = useState(INITIAL_FORM);
  // Errors stay hidden until the first edit of a validated field or a submit, so an untouched form is not red.
  const [showErrors, setShowErrors] = useState(false);
  const nameInput = useRef<HTMLInputElement>(null);
  const errors = showErrors ? validate(form) : {};

  useEffect(() => {
    nameInput.current?.focus();
  }, []);

  const bind: Bind = (key) => ({
    value: form[key],
    onInput: (event) => {
      const { value } = event.currentTarget;
      setForm((current) => ({ ...current, [key]: value }));
      setShowErrors((shown) => shown || VALIDATED.has(key));
    },
  });

  const submit = () => {
    setShowErrors(true);
    if (hasErrors(validate(form))) {
      focusFirstInvalid("newdlg");
      return;
    }
    run(() => request.create(toValues(form)));
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
        <InputField
          id="n_name"
          inputRef={nameInput}
          label={
            <>
              Name <RequiredMark />
            </>
          }
          type="text"
          required
          maxLength={NAME_MAX_LENGTH}
          error={errors.name}
          {...bind("name")}
        />
        <SizeFields errors={errors} bind={bind} />
        <SystemFields bind={bind} />
      </DialogBody>
      <DialogFooter>
        <DialogClose>Cancel</DialogClose>
        <Button type="submit" variant="primary" disabled={busy}>
          Create
        </Button>
      </DialogFooter>
    </DialogForm>
  );
};

export type NewVmDialogProps = {
  readonly request: NewVmRequest;
  readonly onClose: () => void;
};

/** New Virtual Machine form. Fields validate live once edited; Enter submits. */
export const NewVmDialog = ({ request, onClose }: NewVmDialogProps) => (
  <Dialog id="newdlg" titleId="new-title" onClose={onClose}>
    <DialogTitle id="new-title">New Virtual Machine</DialogTitle>
    <NewVmForm request={request} />
  </Dialog>
);
