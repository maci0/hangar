import { useRef, useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogForm, DialogTitle, useDialogClose } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { applyTheme, currentTheme, isTheme } from "@/lib/theme";

/** Form state, all strings as typed. The daemon validates ranges. */
export type PrefsValues = {
  readonly theme: string;
  readonly defaultVmDir: string;
  readonly defaultMemoryMb: string;
  readonly defaultCpuCores: string;
  /** "1" or "0". */
  readonly autoprotectEnabled: string;
  readonly autoprotectIntervalMin: string;
  readonly autoprotectMax: string;
};

export type PrefsRequest = {
  readonly values: PrefsValues;
  /** POSTs the form-encoded body to `/api/config`; resolves whether it was saved. Never rejects. */
  readonly save: (body: string) => Promise<boolean>;
};

type PrefKey = keyof PrefsValues;

/** Form field names the daemon expects, in the order they are sent. */
const API_FIELDS: ReadonlyArray<readonly [PrefKey, string]> = [
  ["theme", "theme"],
  ["defaultVmDir", "default_vm_dir"],
  ["defaultMemoryMb", "default_memory_mb"],
  ["defaultCpuCores", "default_cpu_cores"],
  ["autoprotectEnabled", "autoprotect_enabled"],
  ["autoprotectIntervalMin", "autoprotect_interval"],
  ["autoprotectMax", "autoprotect_max"],
];

const encodeBody = (values: PrefsValues): string =>
  API_FIELDS.map(([key, name]) => `${name}=${encodeURIComponent(values[key])}`).join("&");

type ValueEvent = Event & { readonly currentTarget: { readonly value: string } };

type NumberFieldProps = {
  readonly id: string;
  readonly label: string;
  readonly min: number;
  readonly max: number;
  readonly value: string;
  readonly onInput: (event: ValueEvent) => void;
};

const NumberField = ({ id, label, min, max, value, onInput }: NumberFieldProps) => (
  <Field label={label} htmlFor={id}>
    <Input id={id} type="number" min={min} max={max} step={1} value={value} onInput={onInput} />
  </Field>
);

type ThemeFieldProps = {
  readonly value: string;
  readonly onChange: (theme: string) => void;
};

const ThemeField = ({ value, onChange }: ThemeFieldProps) => (
  <Field label="Theme" htmlFor="p_theme">
    <Select
      id="p_theme"
      value={value}
      onChange={(event) => {
        onChange(event.currentTarget.value);
        // Live preview; closing without saving puts the original back.
        if (isTheme(event.currentTarget.value)) {
          applyTheme(event.currentTarget.value);
        }
      }}
    >
      <option value="system">System</option>
      <option value="light">Light</option>
      <option value="dark">Dark</option>
    </Select>
  </Field>
);

type PrefsFormProps = {
  readonly request: PrefsRequest;
  readonly onSaved: () => void;
};

const PrefsForm = ({ request, onSaved }: PrefsFormProps) => {
  const close = useDialogClose();
  const [values, setValues] = useState(request.values);
  const bind = (key: PrefKey) => ({
    value: values[key],
    onInput: (event: ValueEvent) => setValues((current) => ({ ...current, [key]: event.currentTarget.value })),
  });

  const save = async () => {
    if (await request.save(encodeBody(values))) {
      onSaved();
      close();
    }
  };

  return (
    <DialogForm
      noValidate
      onSubmit={(event) => {
        event.preventDefault();
        save().catch(reportError);
      }}
    >
      <DialogBody class="grid gap-3">
        <ThemeField value={values.theme} onChange={(theme) => setValues((current) => ({ ...current, theme }))} />
        <Field label="Default VM Directory" htmlFor="p_default_vm_dir">
          <Input id="p_default_vm_dir" type="text" placeholder="~/.local/share/hangar" {...bind("defaultVmDir")} />
        </Field>
        <NumberField id="p_default_memory_mb" label="Default Memory (MB)" min={128} max={65_536} {...bind("defaultMemoryMb")} />
        <NumberField id="p_default_cpu_cores" label="Default CPU Cores" min={1} max={256} {...bind("defaultCpuCores")} />
        <Field label="AutoProtect Default" htmlFor="p_autoprotect_enabled">
          <Select
            id="p_autoprotect_enabled"
            value={values.autoprotectEnabled}
            onChange={(event) => setValues((current) => ({ ...current, autoprotectEnabled: event.currentTarget.value }))}
          >
            <option value="0">Off</option>
            <option value="1">On</option>
          </Select>
        </Field>
        <NumberField id="p_autoprotect_interval" label="AutoProtect Interval (min)" min={1} max={1440} {...bind("autoprotectIntervalMin")} />
        <NumberField id="p_autoprotect_max" label="AutoProtect Max Snapshots" min={1} max={100} {...bind("autoprotectMax")} />
      </DialogBody>
      <DialogFooter>
        <DialogClose>Cancel</DialogClose>
        <Button type="submit" variant="primary">
          Save
        </Button>
      </DialogFooter>
    </DialogForm>
  );
};

export type PrefsDialogProps = {
  readonly request: PrefsRequest;
  readonly onClose: () => void;
};

/** Preferences. The theme applies as it is picked and reverts on any close except a save. */
export const PrefsDialog = ({ request, onClose }: PrefsDialogProps) => {
  const originalTheme = useRef(currentTheme());
  const saved = useRef(false);

  const onClosed = () => {
    const original = originalTheme.current;
    if (!saved.current && currentTheme() !== original) {
      applyTheme(original);
    }
    onClose();
  };

  return (
    <Dialog id="prefsdlg" titleId="prefs-title" onClose={onClosed}>
      <DialogTitle id="prefs-title">Preferences</DialogTitle>
      <PrefsForm
        request={request}
        onSaved={() => {
          saved.current = true;
        }}
      />
    </Dialog>
  );
};
