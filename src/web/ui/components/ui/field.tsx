import type { ComponentChildren } from "preact";
import { Input, type InputProps } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { cn } from "@/lib/cn";

const present = (text: string | undefined): text is string => text !== undefined && text !== "";

export type FieldProps = {
  readonly label: ComponentChildren;
  /** Id of the control passed as `children`. */
  readonly htmlFor: string;
  /** Id for the label element, when something else needs to reference it. */
  readonly labelId?: string;
  /** Validation message under the control. Needs `errorId`; the control points `aria-describedby` at it. */
  readonly error?: string;
  readonly errorId?: string;
  /** A warning does not block the form; it reads in the warn color instead of red. */
  readonly errorTone?: FieldErrorTone;
  readonly children: ComponentChildren;
};

export type FieldErrorTone = "error" | "warning";

/** Live region for a validation message; hidden while empty. Exists before the message so screen readers announce it. */
export const FieldError = ({
  id,
  tone = "error",
  children,
}: {
  readonly id: string;
  readonly tone?: FieldErrorTone;
  readonly children?: string;
}) => (
  <div
    id={id}
    aria-live="polite"
    class={cn("text-caption font-medium empty:hidden", tone === "warning" ? "text-warn" : "text-danger-text")}
  >
    {present(children) ? children : null}
  </div>
);

/** A label stacked over its control, with an optional live error line. */
export const Field = ({ label, htmlFor, labelId, error, errorId, errorTone, children }: FieldProps) => (
  <div class="grid gap-1">
    <Label id={labelId} htmlFor={htmlFor}>
      {label}
    </Label>
    {children}
    {errorId !== undefined && (
      <FieldError id={errorId} tone={errorTone}>
        {error}
      </FieldError>
    )}
  </div>
);

/** Props for a control whose `Field` shows `error`. */
export const invalidProps = (error: string | undefined, errorId: string) =>
  present(error) ? { "aria-invalid": true, "aria-describedby": errorId } : {};

export type InputFieldProps = InputProps & {
  readonly id: string;
  readonly label: ComponentChildren;
  /** Validation message; its live region gets the id `err_<id>`. */
  readonly error?: string;
};

/** Labelled `Input` with a validation line. */
export const InputField = ({ id, label, error, ...props }: InputFieldProps) => (
  <Field label={label} htmlFor={id} error={error} errorId={`err_${id}`}>
    <Input id={id} {...invalidProps(error, `err_${id}`)} {...props} />
  </Field>
);

/** Moves focus to the first control marked invalid inside the dialog, once the errors have rendered. */
export const focusFirstInvalid = (dialogId: string): void => {
  requestAnimationFrame(() => document.querySelector<HTMLElement>(`#${dialogId} [aria-invalid]`)?.focus());
};
