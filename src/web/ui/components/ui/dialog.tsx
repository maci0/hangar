import { createContext, type ComponentChildren, type ComponentProps, type RefObject } from "preact";
import { useCallback, useContext, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import { Button, type ButtonProps } from "@/components/ui/button";
import { cn } from "@/lib/cn";

type DialogHandle = { readonly id: string; readonly close: () => void };

const DialogContext = createContext<DialogHandle | null>(null);

const useDialogHandle = (): DialogHandle => {
  const handle = useContext(DialogContext);
  if (handle === null) {
    throw new Error("needs an enclosing Dialog");
  }
  return handle;
};

/** Closes the enclosing `Dialog` through the same path as Escape and the backdrop (guard included). */
export const useDialogClose = (): (() => void) => useDialogHandle().close;

/**
 * Runs an async action from a button or form: `busy` is true while it is pending, the dialog
 * closes when it resolves true, and a rejection is reported without closing.
 */
export const useDialogTask = (): { readonly busy: boolean; readonly run: (task: () => Promise<boolean>) => void } => {
  const close = useDialogClose();
  const [busy, setBusy] = useState(false);
  const run = (task: () => Promise<boolean>): void => {
    const runAndClose = async () => {
      setBusy(true);
      try {
        if (await task()) {
          close();
        }
      } finally {
        setBusy(false);
      }
    };
    runAndClose().catch(reportError);
  };
  return { busy, run };
};

type Guard = () => boolean | Promise<boolean>;

/**
 * Returns `close()`: consult the guard, play the exit animation, then close the element.
 * Overlapping calls are ignored, so Escape during a pending guard prompt does not stack prompts.
 * It also replaces `dlg.close`, so callers that hold the element (the Escape sweep, the topology's
 * jump to a VM) get the same guard and animation.
 */
const useGuardedClose = (ref: RefObject<HTMLDialogElement>, guard: Guard | undefined): (() => void) => {
  const busy = useRef(false);
  const latestGuard = useRef(guard);
  latestGuard.current = guard;
  const nativeClose = useRef<(() => void) | null>(null);

  const request = useCallback(async () => {
    const dlg = ref.current;
    if (dlg === null || !dlg.open || busy.current) {
      return;
    }
    busy.current = true;
    try {
      if (!(await (latestGuard.current?.() ?? true))) {
        return;
      }
      dlg.dataset.closing = "";
      // No running animation (reduced motion) leaves nothing to wait for.
      await Promise.allSettled(dlg.getAnimations().map((animation) => animation.finished));
      nativeClose.current?.();
    } finally {
      busy.current = false;
    }
  }, [ref]);

  const close = useCallback(() => {
    request().catch(reportError);
  }, [request]);

  useLayoutEffect(() => {
    const dlg = ref.current;
    if (dlg === null) {
      return;
    }
    nativeClose.current = dlg.close.bind(dlg);
    dlg.close = close;
  }, [ref, close]);

  return close;
};

export type DialogProps = {
  readonly id: string;
  /** Id of the element inside that names the dialog (`aria-labelledby`). */
  readonly titleId: string;
  readonly class?: string;
  /** Runs once the dialog has closed, by any path. The owner unmounts the dialog here. */
  readonly onClose: () => void;
  /** Consulted before every close (button, Escape, backdrop); resolving false keeps it open. */
  readonly guard?: Guard;
  readonly children: ComponentChildren;
};

/**
 * Modal built on the native `<dialog>`: mounting opens it with `showModal()`, so focus moves
 * in and the page behind is inert. Escape, backdrop clicks and `dlg.close()` all go through
 * the guard and the exit animation. Focus returns to the element that had it on open.
 */
export const Dialog = ({ id, titleId, class: className, guard, onClose, children }: DialogProps) => {
  const ref = useRef<HTMLDialogElement>(null);
  const opener = useRef<Element | null>(null);
  const mounted = useRef(false);
  const latestOnClose = useRef(onClose);
  latestOnClose.current = onClose;
  const close = useGuardedClose(ref, guard);
  const handle = useMemo(() => ({ id, close }), [id, close]);

  // Layout effect: runs before the children's effects, so they can focus inside an open dialog.
  useLayoutEffect(() => {
    opener.current = document.activeElement;
    ref.current?.showModal();
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const onClosed = () => {
    if (!mounted.current) {
      return;
    }
    if (opener.current instanceof HTMLElement && opener.current.isConnected) {
      opener.current.focus();
    }
    latestOnClose.current();
  };

  return (
    <DialogContext.Provider value={handle}>
      <dialog
        ref={ref}
        id={id}
        aria-labelledby={titleId}
        class={cn(
          "inset-0 m-auto w-120 max-w-11/12 transform-none flex-col overflow-hidden rounded-lg border border-border bg-surface p-0 text-fg shadow-dialog open:flex backdrop:bg-backdrop backdrop:backdrop-blur-dialog backdrop:backdrop-saturate-115 animate-dialog-in data-closing:pointer-events-none data-closing:animate-dialog-out motion-reduce:animate-none",
          className,
        )}
        onClose={onClosed}
        onCancel={(event) => {
          event.preventDefault();
          close();
        }}
        onClick={(event) => {
          if (event.target === event.currentTarget) {
            close();
          }
        }}
      >
        {children}
      </dialog>
    </DialogContext.Provider>
  );
};

/** Button that closes its dialog. `data-action="closeDlg"` is a hook for tests. */
export const DialogClose = ({ onClick, ...props }: ButtonProps) => {
  const { id, close } = useDialogHandle();
  return (
    <Button
      type="button"
      data-action="closeDlg"
      data-dialog={id}
      {...props}
      onClick={(event) => {
        onClick?.call(event.currentTarget, event);
        close();
      }}
    />
  );
};

export type DialogTitleProps = ComponentProps<"h2">;

export const DialogTitle = ({ class: className, ...props }: DialogTitleProps) => (
  <h2 class={cn("border-b border-border px-5 pt-3 pb-2.5 text-title font-semibold", className)} {...props} />
);

export type DialogBodyProps = ComponentProps<"div">;

export const DialogBody = ({ class: className, ...props }: DialogBodyProps) => (
  <div class={cn("min-h-0 flex-1 overflow-y-auto px-5 py-4", className)} {...props} />
);

export type DialogFooterProps = ComponentProps<"div">;

/** Button row, right-aligned with the primary action last. */
export const DialogFooter = ({ class: className, ...props }: DialogFooterProps) => (
  <div class={cn("flex flex-wrap justify-end gap-2 border-t border-border-soft px-5 pt-3 pb-4", className)} {...props} />
);

export type DialogFormProps = ComponentProps<"form">;

/** Wrap body and footer to get Enter-to-submit while keeping the body the scrolling part. */
export const DialogForm = ({ class: className, ...props }: DialogFormProps) => (
  <form class={cn("flex min-h-0 flex-1 flex-col", className)} {...props} />
);
