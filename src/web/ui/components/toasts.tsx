import { useEffect, useState } from "preact/hooks";
import { Icon } from "@/components/icon";
import { cn } from "@/lib/cn";

export type ToastType = "success" | "error" | "info" | "warn";

export type ToastRequest = {
  readonly message: string;
  readonly type: ToastType;
  /** Milliseconds on screen; defaults by type. */
  readonly duration?: number;
  /** An UNDO button that runs `run` and dismisses the toast. */
  readonly undo?: () => void;
};

export type ToastEntry = ToastRequest & { readonly id: number };

/** Older toasts are dropped beyond this many. */
export const MAX_TOASTS = 5;
const EXIT_MS = 280;
const DEFAULT_MS: Readonly<Record<ToastType, number>> = { success: 4000, info: 4000, warn: 5000, error: 6500 };

const ICON: Readonly<Record<ToastType, string>> = { success: "check", error: "x", info: "info", warn: "alert" };
const ACCENT: Readonly<Record<ToastType, { readonly edge: string; readonly icon: string }>> = {
  success: { edge: "border-l-success", icon: "text-success" },
  error: { edge: "border-l-danger", icon: "text-danger" },
  warn: { edge: "border-l-warn", icon: "text-warn" },
  info: { edge: "border-l-accent", icon: "text-accent" },
};

const prefersReducedMotion = (): boolean => globalThis.matchMedia("(prefers-reduced-motion: reduce)").matches;

const Toast = ({ toast, onDone }: { readonly toast: ToastEntry; readonly onDone: (id: number) => void }) => {
  const [exiting, setExiting] = useState(false);
  const { id, type, message, undo } = toast;

  useEffect(() => {
    const timers: Array<ReturnType<typeof setTimeout>> = [];
    timers.push(
      setTimeout(() => {
        if (prefersReducedMotion()) {
          onDone(id);
          return;
        }
        setExiting(true);
        timers.push(setTimeout(() => onDone(id), EXIT_MS));
      }, toast.duration ?? DEFAULT_MS[type]),
    );
    return () => {
      for (const timer of timers) {
        clearTimeout(timer);
      }
    };
  }, [id, type, toast.duration, onDone]);

  return (
    <div
      class={cn(
        "toast pointer-events-auto flex max-h-32.5 max-w-95 items-center gap-2.25 overflow-hidden rounded-md border border-l-3 border-border bg-surface px-3 py-2.25 text-field text-fg shadow-menu max-phone:max-w-none",
        ACCENT[type].edge,
        exiting ? "exit animate-toast-out" : "animate-toast-in",
        type,
      )}
      role={type === "error" || type === "warn" ? "alert" : "status"}
    >
      <span class={cn("toast-icon inline-flex items-center justify-center", ACCENT[type].icon)} aria-hidden="true">
        <Icon name={ICON[type]} />
      </span>
      <span class="toast-msg flex-1 wrap-anywhere">{message}</span>
      {undo !== undefined && (
        <button
          type="button"
          class="toast-action min-h-6 rounded-sm border border-accent bg-transparent px-2.25 py-1.25 text-caption font-bold text-fg uppercase hover:bg-accent hover:text-on-accent focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent pointer-coarse:min-h-11"
          data-toast-action="undo"
          onClick={() => {
            undo();
            onDone(id);
          }}
        >
          Undo
        </button>
      )}
    </div>
  );
};

/**
 * Toast stack. The container is the live region and stays mounted while empty: a region must
 * exist before its content changes for additions to be announced.
 */
export const Toasts = ({ toasts, onDone }: { readonly toasts: ReadonlyArray<ToastEntry>; readonly onDone: (id: number) => void }) => (
  <div
    id="toast-container"
    class="pointer-events-none fixed top-13 right-3.5 z-200 flex flex-col gap-2 max-phone:right-2 max-phone:left-2"
    role="log"
    aria-live="polite"
    aria-relevant="additions"
  >
    {toasts.map((toast) => (
      <Toast key={toast.id} toast={toast} onDone={onDone} />
    ))}
  </div>
);
