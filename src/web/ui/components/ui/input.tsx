import type { ComponentProps } from "preact";
import { cn } from "@/lib/cn";

/** Text-like control chrome, shared with `Select` so both read as one family. */
export const fieldClass =
  "block min-h-6.5 w-full rounded-sm border border-border bg-bg px-2 py-0.75 text-field text-fg outline-0 transition-colors hover:border-border-hover focus-visible:border-accent focus-visible:ring-3 focus-visible:ring-accent-soft read-only:text-fg-dim aria-invalid:border-danger-text aria-invalid:ring-2 aria-invalid:ring-danger-soft pointer-coarse:min-h-11";

export type InputProps = ComponentProps<"input">;

export const Input = ({ class: className, ...props }: InputProps) => (
  <input class={cn(fieldClass, "empty-hint", className)} {...props} />
);
