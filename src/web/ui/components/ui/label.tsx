import type { ComponentProps } from "preact";
import { cn } from "@/lib/cn";

export type LabelProps = ComponentProps<"label">;

export const Label = ({ class: className, ...props }: LabelProps) => (
  <label class={cn("block text-caption font-semibold text-fg-muted", className)} {...props} />
);
