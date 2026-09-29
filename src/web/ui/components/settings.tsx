import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { Button } from "@/components/ui/button";
import { Field, invalidProps } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { RequiredMark } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/cn";
import {
  buildSections,
  fieldLocked,
  hardwareLocked,
  firstError,
  initialValues,
  isDirty,
  lockNotice,
  settingsBody,
  validateSettings,
  type FieldTools,
  type HardwareSlots,
  type Issue,
  type Issues,
  type SettingField,
  type SettingsSection,
  type SettingValues,
} from "@/lib/settings";
import type { Vm } from "@/lib/vm";

/** The buttons under the media and disk fields. Each name is also the button's `data-action` test hook. */
export type SettingsTools = {
  readonly changeCd: () => void;
  readonly ejectCd: () => void;
  readonly resizeDisk: () => void;
  readonly compactDisk: () => void;
  readonly disk2upload: () => void;
  readonly disk2download: () => void;
};

/** What the app hands over to edit one VM. */
export type SettingsRequest = {
  readonly vm: Vm;
  readonly slots: HardwareSlots;
  /** Persists the form body. Resolves true when the daemon accepted it. */
  readonly save: (body: string) => Promise<boolean>;
  /** Reports whether the form differs from where it started. */
  readonly onDirty: (dirty: boolean) => void;
  /** Called when Save is refused because a field is invalid. */
  readonly onInvalid: () => void;
};

/** A request plus the handlers the panel bridge supplies. */
export type SettingsFormRequest = SettingsRequest & {
  readonly tools: SettingsTools;
  /** Leaves the form without saving (Cancel). */
  readonly cancel: () => void;
};

/** Lets code outside the tree (Ctrl+S, `saveVm`) submit the open form. */
export const settingsControl = {
  submit: (): void => undefined,
};

const LOCKED_TITLE = "Power off the VM to change virtual hardware";
const SAVE_LABEL = "Save Changes";
const SAVING_LABEL = "Saving...";

const TOOLS: Readonly<Record<FieldTools, ReadonlyArray<{ readonly action: keyof SettingsTools; readonly label: string }>>> = {
  media: [
    { action: "changeCd", label: "Change CD/ISO" },
    { action: "ejectCd", label: "Eject CD/ISO" },
  ],
  disk: [
    { action: "resizeDisk", label: "Resize Primary Disk" },
    { action: "compactDisk", label: "Compact Primary Disk" },
  ],
  disk2: [
    { action: "disk2upload", label: "Upload Disk 2" },
    { action: "disk2download", label: "Download Disk 2" },
  ],
};

const FieldToolButtons = ({ tools, handlers }: { readonly tools: FieldTools; readonly handlers: SettingsTools }) => (
  <div class="flex flex-wrap gap-1.5">
    {TOOLS[tools].map(({ action, label }) => (
      <Button key={action} type="button" data-action={action} onClick={handlers[action]}>
        {label}
      </Button>
    ))}
  </div>
);

type ControlProps = {
  readonly field: SettingField;
  readonly value: string;
  readonly issue: Issue | undefined;
  readonly locked: boolean;
  readonly onChange: (next: string) => void;
};

/** An error marks the control invalid; a warning only points at its message. */
const issueProps = (issue: Issue | undefined, errorId: string) => {
  if (issue === undefined) {
    return {};
  }
  if (issue.severity === "error") {
    return invalidProps(issue.message, errorId);
  }
  return { "aria-describedby": errorId };
};

const SettingControl = ({ field, value, issue, locked, onChange }: ControlProps) => {
  const { control } = field;
  const id = `e_${field.key}`;
  const shared = { id, disabled: locked, title: locked ? LOCKED_TITLE : undefined, ...issueProps(issue, `err_${id}`) };
  const onInput = (event: { readonly currentTarget: { readonly value: string } }) => onChange(event.currentTarget.value);
  if (control.kind === "select") {
    return (
      <Select {...shared} value={value} onChange={(event) => onChange(event.currentTarget.value)}>
        {control.options.map((choice) => (
          <option key={choice.value} value={choice.value}>
            {choice.label}
          </option>
        ))}
      </Select>
    );
  }
  if (control.kind === "textarea") {
    return <Textarea {...shared} rows={6} spellcheck={false} placeholder={control.placeholder} value={value} onInput={onInput} />;
  }
  if (control.kind === "number") {
    return (
      <Input
        {...shared}
        type="number"
        min={control.min}
        max={control.max}
        step={control.step}
        required={field.required}
        value={value}
        onInput={onInput}
      />
    );
  }
  return (
    <Input
      {...shared}
      type="text"
      placeholder={control.placeholder}
      pattern={control.pattern}
      maxLength={control.maxLength}
      required={field.required}
      value={value}
      onInput={onInput}
    />
  );
};

const SettingRow = ({ tools, ...props }: ControlProps & { readonly tools: SettingsTools }) => {
  const { field, issue } = props;
  const id = `e_${field.key}`;
  return (
    <Field
      label={
        <>
          {field.label}
          {field.required === true && (
            <>
              {" "}
              <RequiredMark />
            </>
          )}
        </>
      }
      htmlFor={id}
      error={issue?.message}
      errorId={`err_${id}`}
      errorTone={issue?.severity === "warning" ? "warning" : "error"}
    >
      <SettingControl {...props} />
      {field.tools !== undefined && <FieldToolButtons tools={field.tools} handlers={tools} />}
    </Field>
  );
};

type NavProps = {
  readonly sections: ReadonlyArray<SettingsSection>;
  readonly category: string;
  readonly onSelect: (id: string) => void;
};

const Nav = ({ sections, category, onSelect }: NavProps) => {
  const current = useRef<HTMLButtonElement>(null);
  // On a phone the nav scrolls sideways; keep the current category in view.
  useEffect(() => {
    current.current?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [category]);
  return (
    <nav
      class="settings-nav sticky top-0 grid gap-px rounded-md border border-border-soft bg-surface p-1 max-narrow:static max-narrow:flex max-narrow:overflow-x-auto"
      aria-label="Settings categories"
    >
      {sections.map((section) => {
        const active = section.id === category;
        return (
          <button
            key={section.id}
            ref={active ? current : undefined}
            type="button"
            class={cn(
              "settings-nav-item block rounded-sm border-0 border-l-2 border-transparent bg-transparent px-2.25 py-1.75 text-left transition-colors hover:bg-surface-2 focus-visible:outline-2 -outline-offset-2 focus-visible:outline-accent max-narrow:flex-none pointer-coarse:min-h-11",
              active && "active border-accent bg-accent-soft",
            )}
            aria-current={active ? "page" : undefined}
            data-action="setSettingsCategory"
            data-settings-category={section.id}
            onClick={() => onSelect(section.id)}
          >
            <span class={cn("block text-field font-semibold whitespace-nowrap", active ? "text-accent-2" : "text-fg")}>{section.title}</span>
            <small class={`mt-px block text-caption leading-snug max-narrow:hidden ${active ? "text-fg-muted" : "text-fg-dim"}`}>
              {section.note}
            </small>
          </button>
        );
      })}
    </nav>
  );
};

type PanelProps = {
  readonly section: SettingsSection;
  readonly active: boolean;
  readonly values: SettingValues;
  readonly issues: Issues;
  readonly status: Vm["status"];
  readonly tools: SettingsTools;
  readonly onChange: (key: string, next: string) => void;
};

/** Every panel stays in the page and inactive ones are hidden, so each control keeps its `e_<key>` id. */
const Panel = ({ section, active, values, issues, status, tools, onChange }: PanelProps) => (
  <section
    class={cn(
      "settings-panel mb-3 rounded-md border border-border-soft bg-surface p-3.5 shadow-card max-phone:p-2.5",
      active ? "active" : "hidden",
    )}
    data-settings-panel={section.id}
  >
    <div class="mb-3 border-b border-border-soft pb-2">
      <h3 class="text-title leading-tight font-semibold">{section.title}</h3>
      <p class="mt-0.75 text-xs text-fg-dim">{section.note}</p>
    </div>
    <div class="settings-form grid grid-cols-fields items-start gap-x-4 gap-y-3 max-phone:grid-cols-1">
      {section.fields.map((field) => (
        <SettingRow
          key={field.key}
          field={field}
          value={values[field.key] ?? ""}
          issue={issues[field.key]}
          locked={fieldLocked(field.key, status)}
          tools={tools}
          onChange={(next) => onChange(field.key, next)}
        />
      ))}
    </div>
  </section>
);

type Submit = {
  readonly request: SettingsRequest;
  readonly values: SettingValues;
  readonly sections: ReadonlyArray<SettingsSection>;
  readonly onInvalid: (key: string, section: string) => void;
};

/**
 * Validates and saves. While a request is pending the form is busy; the same function runs for the Save
 * button and Ctrl+S (through `settingsControl`).
 */
const useSubmit = ({ request, values, sections, onInvalid }: Submit): { readonly busy: boolean; readonly submit: () => void } => {
  const [busy, setBusy] = useState(false);
  const submit = async (): Promise<void> => {
    if (busy) {
      return;
    }
    const bad = firstError(sections, validateSettings(values, request.slots));
    if (bad !== null) {
      onInvalid(bad.key, bad.section);
      request.onInvalid();
      return;
    }
    setBusy(true);
    try {
      await request.save(settingsBody(values, request.slots));
    } finally {
      setBusy(false);
    }
  };
  const latest = useRef(submit);
  latest.current = submit;
  useEffect(() => {
    settingsControl.submit = () => {
      void latest.current();
    };
    return () => {
      settingsControl.submit = () => undefined;
    };
  }, []);
  return { busy, submit: () => void latest.current() };
};

type FocusRequest = { readonly key: string; readonly count: number };

type FormState = {
  readonly sections: ReadonlyArray<SettingsSection>;
  readonly values: SettingValues;
  readonly issues: Issues;
  readonly busy: boolean;
  readonly submit: () => void;
  readonly setField: (key: string, next: string) => void;
};

/** Form values, validation shown once the user edits or saves, dirty reporting, and focus on the first bad field. */
const useSettingsForm = (request: SettingsRequest, onCategory: (id: string) => void): FormState => {
  const { vm, slots } = request;
  const sections = useMemo(() => buildSections(slots), [slots]);
  const initial = useMemo(() => initialValues(vm, sections), [vm, sections]);
  const [values, setValues] = useState<SettingValues>(initial);
  const [checked, setChecked] = useState(false);
  const [focusRequest, setFocusRequest] = useState<FocusRequest | null>(null);
  const dirty = isDirty(values, initial);

  useEffect(() => {
    request.onDirty(dirty);
  }, [dirty, request]);
  useEffect(() => {
    if (focusRequest !== null) {
      document.querySelector<HTMLElement>(`#e_${focusRequest.key}`)?.focus();
    }
  }, [focusRequest]);

  const { busy, submit } = useSubmit({
    request,
    values,
    sections,
    onInvalid: (key, section) => {
      setChecked(true);
      onCategory(section);
      setFocusRequest((current) => ({ key, count: (current?.count ?? 0) + 1 }));
    },
  });
  return {
    sections,
    values,
    busy,
    submit,
    issues: checked ? validateSettings(values, slots) : {},
    setField: (key, next) => {
      setChecked(true);
      setValues((current) => ({ ...current, [key]: next }));
    },
  };
};

const ActionBar = ({ busy, onCancel, onSave }: { readonly busy: boolean; readonly onCancel: () => void; readonly onSave: () => void }) => (
  <div class="settings-actions sticky bottom-0 z-30 -mx-3.5 mt-3.5 -mb-3.5 flex justify-end gap-2 border-t border-border bg-bg-alt px-3.5 py-2.5">
    <Button type="button" onClick={onCancel}>
      Cancel
    </Button>
    <Button id="savevmbtn" type="button" variant="primary" onClick={onSave} title="Save VM settings">
      {busy ? SAVING_LABEL : SAVE_LABEL}
    </Button>
  </div>
);

/** VM Settings tab: category nav, one panel per category, and the Cancel and Save bar. */
export const SettingsForm = ({
  request,
  category,
  onCategory,
}: {
  readonly request: SettingsFormRequest;
  readonly category: string;
  readonly onCategory: (id: string) => void;
}) => {
  const { sections, values, issues, busy, submit, setField } = useSettingsForm(request, onCategory);
  const active = sections.some((section) => section.id === category) ? category : (sections[0]?.id ?? "");
  const { status } = request.vm;
  return (
    <>
      {hardwareLocked(status) && (
        <div
          class="settings-runlock mb-2.5 rounded-sm border border-l-3 border-warn/50 border-l-warn bg-surface px-3 py-2 text-xs text-fg-muted"
          role="note"
        >
          {lockNotice(status)}
        </div>
      )}
      <fieldset class="m-0 min-w-0 border-0 p-0" disabled={busy}>
        <div class="settings-shell grid grid-cols-settings items-start gap-3 max-narrow:grid-cols-1">
          <Nav sections={sections} category={active} onSelect={onCategory} />
          <div class="min-w-0">
            {sections.map((section) => (
              <Panel
                key={section.id}
                section={section}
                active={section.id === active}
                values={values}
                issues={issues}
                status={status}
                tools={request.tools}
                onChange={setField}
              />
            ))}
          </div>
        </div>
        <ActionBar busy={busy} onCancel={request.cancel} onSave={submit} />
      </fieldset>
    </>
  );
};
