import type { ComponentChildren } from "preact";
import { Icon } from "@/components/icon";

export type EmptyStateProps = {
  /** Sprite symbol drawn on the accent tile. */
  readonly icon: string;
  readonly title: string;
  readonly children: ComponentChildren;
  /** Buttons under the message. */
  readonly actions?: ComponentChildren;
};

/** Message and optional buttons for a panel with nothing to show. */
export const EmptyState = ({ icon, title, children, actions }: EmptyStateProps) => (
  <div class="flex min-h-95 flex-col items-center justify-center rounded-md border border-border-soft bg-bg-alt px-6 py-12 text-center text-fg-dim max-phone:min-h-85 max-phone:px-4 max-phone:py-10">
    <Icon name={icon} class="mb-4.5 size-16 rounded-md bg-accent-soft p-3.75 text-accent" />
    <h3 class="mb-1.75 text-heading font-semibold tracking-tight text-fg">{title}</h3>
    <p class="max-w-107 text-field leading-relaxed text-fg-muted">{children}</p>
    {actions !== undefined && <div class="mt-4 flex flex-wrap justify-center gap-2">{actions}</div>}
  </div>
);
