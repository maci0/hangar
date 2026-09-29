import { cva, type VariantProps } from "class-variance-authority";
import type { ComponentProps } from "preact";
import { cn } from "@/lib/cn";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-1.5 rounded-md border text-sm font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:opacity-50 disabled:pointer-events-none",
  {
    variants: {
      variant: {
        default: "bg-surface-2 border-border-soft text-fg hover:bg-surface-3",
        primary: "bg-accent border-accent text-on-accent hover:bg-accent-hover",
        danger: "bg-danger border-danger text-on-danger",
      },
      size: { default: "h-8 px-3", icon: "h-8 w-8" },
    },
    defaultVariants: { variant: "default", size: "default" },
  },
);

export type ButtonProps = ComponentProps<"button"> & VariantProps<typeof buttonVariants>;

export const Button = ({ class: className, variant, size, ...props }: ButtonProps) => (
  <button class={cn(buttonVariants({ variant, size }), className)} {...props} />
);
