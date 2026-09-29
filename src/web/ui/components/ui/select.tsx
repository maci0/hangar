import type { ComponentProps } from "preact";
import { fieldClass } from "@/components/ui/input";
import { cn } from "@/lib/cn";

export type SelectProps = ComponentProps<"select">;

/** Native select (keyboard and screen reader behavior for free) with the `Input` chrome. */
export const Select = ({ class: className, ...props }: SelectProps) => (
  <select class={cn(fieldClass, className)} {...props} />
);
