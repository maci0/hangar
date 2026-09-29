import type { ComponentChildren } from "preact";
import { Label } from "@/components/ui/label";

export type FieldProps = {
  readonly label: ComponentChildren;
  /** Id of the control passed as `children`. */
  readonly htmlFor: string;
  /** Id for the label element, when something else needs to reference it. */
  readonly labelId?: string;
  readonly children: ComponentChildren;
};

/** A label stacked over its control. */
export const Field = ({ label, htmlFor, labelId, children }: FieldProps) => (
  <div class="grid gap-1">
    <Label id={labelId} htmlFor={htmlFor}>{label}</Label>
    {children}
  </div>
);
