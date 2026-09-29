import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";

const KEY_CAP = "rounded-xs border border-white/20 bg-white/15 px-1.25 py-px text-caption text-inherit";

export type DisplayOnlyBarProps = {
  /** Shown for a few seconds after entering, so a first-time user finds the way out. */
  readonly revealed: boolean;
};

/**
 * Exit bar of display-only mode. It is invisible and does not take pointer events (the guest gets
 * every click), and appears on keyboard focus, for a few seconds after entering, and always on touch
 * screens.
 */
export const DisplayOnlyBar = ({ revealed }: DisplayOnlyBarProps) => (
  <div
    class={cn(
      "pointer-events-none fixed inset-x-0 top-0 z-10000 hidden items-center gap-3 bg-black/72 px-3 py-1 text-caption text-white/85 opacity-0 transition-opacity displayonly:flex focus-within:pointer-events-auto focus-within:opacity-100 no-hover:pointer-events-auto no-hover:opacity-100",
      revealed && "pointer-events-auto opacity-100",
    )}
  >
    <span>Display-only mode</span>
    <kbd class={KEY_CAP}>F11</kbd>
    <span>or</span>
    <kbd class={KEY_CAP}>Esc</kbd>
    <span>to exit</span>
    <Button
      variant="ghost"
      class="ml-auto min-h-6 border-white/35 bg-white/12 px-2.5 py-0.5 font-semibold text-white hover:bg-white/22 hover:text-white focus-visible:outline-white"
      data-action="exitDisplayOnly"
      aria-label="Exit display-only mode"
    >
      Exit
    </Button>
  </div>
);
