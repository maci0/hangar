import type { ComponentProps } from "preact";
import { cn } from "@/lib/cn";

export type LabelProps = ComponentProps<"label">;

export const Label = ({ class: className, ...props }: LabelProps) => (
  <label class={cn("block text-caption font-semibold text-fg-muted", className)} {...props} />
);

/** Asterisk after the label text of a required field; the control carries `required`. */
export const RequiredMark = () => (
  <span aria-hidden="true" class="font-bold text-danger-text">
    *
  </span>
);

/** Parenthesized note inside a label, such as "(optional)". */
export const LabelHint = ({ class: className, ...props }: ComponentProps<"span">) => (
  <span class={cn("font-normal text-fg-dim", className)} {...props} />
);
