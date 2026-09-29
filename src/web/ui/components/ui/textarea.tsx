import type { ComponentProps } from "preact";
import { fieldClass } from "@/components/ui/input";
import { cn } from "@/lib/cn";

export type TextareaProps = ComponentProps<"textarea">;

/** Multi-line text with the `Input` chrome; monospace because it holds config text. */
export const Textarea = ({ class: className, ...props }: TextareaProps) => (
  <textarea class={cn(fieldClass, "empty-hint resize-y font-mono", className)} {...props} />
);
