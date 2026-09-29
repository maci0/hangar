import { cn } from "@/lib/cn";
import type { OsBrand, VmStatus } from "@/lib/vm";

const DOT_TONE: Readonly<Record<VmStatus, string>> = {
  running: "bg-success ring-2 ring-success/20",
  paused: "bg-pause",
  suspended: "bg-warn",
  stopped: "bg-fg-dim",
};

/** State dot before the state name; the name carries the meaning, the dot only colors it. */
export const StatusDot = ({ status }: { readonly status: VmStatus }) => (
  <span class={cn("mr-1.5 inline-block size-1.75 rounded-full align-middle", DOT_TONE[status])} aria-hidden="true" />
);

/** Small OS emblem: monogram on the brand color. 20px, `rounded-sm` on the emblem radius scale. */
export const OsBadge = ({ brand }: { readonly brand: OsBrand }) => (
  <span
    class="inline-flex size-5 flex-none items-center justify-center rounded-sm text-caption leading-none font-bold text-white"
    style={{ background: brand.color }}
    aria-hidden="true"
  >
    {brand.text}
  </span>
);

export const TagChip = ({ children }: { readonly children: string }) => (
  <span class="mr-1 inline-block rounded-full border border-accent/25 bg-accent-soft px-2 py-px text-caption font-semibold text-accent">
    {children}
  </span>
);
