import { cva, type VariantProps } from "class-variance-authority";
import type { ComponentProps } from "preact";
import { cn } from "@/lib/cn";

/** Mirrors the legacy `.btn` rule in app.css, expressed through the shared tokens. */
const buttonVariants = cva(
  "inline-flex min-h-6.5 items-center justify-center gap-1.25 rounded-sm border px-2.5 py-0.75 text-xs font-medium whitespace-nowrap select-none transition-colors focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-45 max-md:min-h-11",
  {
    variants: {
      variant: {
        default: "border-border bg-surface-2 text-fg-muted hover:border-border-hover hover:bg-surface-3 hover:text-fg",
        primary: "border-accent bg-accent font-semibold text-on-accent hover:border-accent-hover hover:bg-accent-hover",
        danger: "border-danger/55 bg-transparent text-danger-text hover:border-danger hover:bg-danger hover:text-on-danger",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

export type ButtonProps = ComponentProps<"button"> & VariantProps<typeof buttonVariants>;

export const Button = ({ class: className, variant, ...props }: ButtonProps) => (
  <button class={cn(buttonVariants({ variant }), className)} {...props} />
);
