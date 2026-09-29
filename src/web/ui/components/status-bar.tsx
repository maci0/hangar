import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";

export type StatusBarProps = {
  readonly text: string;
  /** A request is pending: the message pulses. */
  readonly loading: boolean;
  /** The event stream is connected. */
  readonly live: boolean;
  /**
   * Text for screen readers. Only intentional messages go here, so the bar's frequent passive
   * updates (uptime, VM counts) stay silent.
   */
  readonly announcement: string;
};

/** Bottom bar: status message, live indicator, and the screen-reader announcer. */
export const StatusBar = ({ text, loading, live, announcement }: StatusBarProps) => (
  <>
    <div
      id="statusbar"
      class="relative z-100 col-span-full row-start-3 flex min-h-6 items-center gap-3 border-t border-border bg-bg-alt px-3 py-0.75 text-xs text-fg-muted tabular-nums displayonly:hidden"
    >
      <span id="statusmsg" class={cn("min-w-0 flex-1 truncate", loading && "loading animate-status-pulse")}>
        {text}
      </span>
      {live && (
        <span
          id="livebadge"
          class="inline-flex items-center gap-1.25 text-caption font-semibold tracking-wider text-fg-dim uppercase"
        >
          <span class="size-1.5 rounded-full bg-success ring-2 ring-success/20 animate-live-pulse" aria-hidden="true" />
          Live
        </span>
      )}
    </div>
    <div id="statusannounce" class="sr-only" role="status" aria-live="polite">
      {announcement}
    </div>
  </>
);

/** Shown while the daemon is unreachable; Dismiss hides it until the next outage. */
export const ConnectionBanner = ({ visible }: { readonly visible: boolean }) => (
  <div
    id="connbanner"
    class={cn(
      "z-200 col-span-full w-full items-center justify-center gap-3 bg-warn px-4 py-1.5 text-xs font-semibold text-on-warn",
      visible ? "flex" : "hidden",
    )}
    role="alert"
    aria-live="assertive"
  >
    <span>Connection lost: retrying automatically</span>
    <Button data-action="dismissBanner">Dismiss</Button>
  </div>
);
