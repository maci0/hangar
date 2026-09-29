import type { Ref } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";
import {
  clampSerialHeight,
  consoleNotice,
  isGpuRenderer,
  SERIAL_DEFAULT_HEIGHT,
  SERIAL_MAX_HEIGHT,
  SERIAL_MIN_HEIGHT,
  serialHeightForKey,
} from "@/lib/console";
import type { DisplayHint, DisplayState } from "@/lib/display";
import type { SerialState } from "@/lib/serial";
import type { Vm } from "@/lib/vm";

const DISPLAY_ONLY_TITLE = "Display only";
const RECONNECT_TITLE = "Reconnect display";
const CAD_TITLE = "Send Ctrl+Alt+Del";

/** Buttons over the display keep the dark glass look in both themes. */
const ON_DISPLAY_BUTTON =
  "border-white/22 bg-black/60 font-semibold text-white/88 hover:border-white/22 hover:bg-white/16 hover:text-white/88";
const TOOL_BUTTON = cn(
  "inline-flex min-h-6.5 min-w-6.5 items-center justify-center rounded-sm border px-1.5 text-caption focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-40 pointer-coarse:min-h-11",
  ON_DISPLAY_BUTTON,
);

type DisplayToolProps = {
  readonly action: string;
  readonly icon: string;
  readonly title: string;
  /** Why the button is off, or null when it works. */
  readonly reason: string | null;
};

const DisplayTool = ({ action, icon, title, reason }: DisplayToolProps) => (
  <button
    type="button"
    class={TOOL_BUTTON}
    data-action={action}
    title={reason ?? title}
    aria-label={title}
    disabled={reason !== null}
    aria-disabled={reason !== null}
  >
    <Icon name={icon} class="size-3.5" />
  </button>
);

const HintContent = ({ hint }: { readonly hint: DisplayHint }) => {
  if (hint.kind === "loading") {
    return <span class="text-xs text-white/70">Loading {hint.client} client…</span>;
  }
  if (hint.kind === "failed") {
    return (
      <>
        <strong class="font-semibold">{hint.client} client failed to load.</strong>
        <Button data-action="reconnectDisplay" class={ON_DISPLAY_BUTTON}>
          Retry
        </Button>
      </>
    );
  }
  if (hint.kind === "native") {
    return (
      <>
        <strong class="font-semibold">Native {hint.label} display</strong>
        <span class="max-w-130 text-xs text-white/60">
          Browser console requires embedded VNC or SPICE. Change Display & Video in Settings to use this pane.
        </span>
      </>
    );
  }
  return null;
};

export type DisplayViewProps = {
  readonly state: DisplayState;
  /** Why the display buttons are off, or null. */
  readonly displayReason: string | null;
  readonly cadReason: string | null;
  /** A stable callback: the controller mounts the clients into this element. */
  readonly elementRef: Ref<HTMLDivElement>;
};

/** `#display`: the box the noVNC and SPICE clients paint into, with its badge, buttons and message. */
export const DisplayView = ({ state, displayReason, cadReason, elementRef }: DisplayViewProps) => {
  const { hint } = state;
  return (
    <div
      id="display"
      ref={elementRef}
      role="group"
      aria-label="VM console"
      aria-describedby="displayHint"
      data-renderer={state.renderer ?? undefined}
      data-gpu={isGpuRenderer(state.renderer) ? "" : undefined}
      data-video={state.video ? "" : undefined}
      class={cn(
        "display-surface relative mb-3.5 min-h-40 overflow-hidden rounded-md border border-border bg-display displayonly:m-0 displayonly:block displayonly:h-screen displayonly:w-screen displayonly:rounded-none displayonly:border-0 displayonly:bg-black",
        !state.visible && "hidden",
      )}
    >
      <div
        id="displayBadge"
        aria-hidden="true"
        class={cn(
          "pointer-events-none absolute top-2 right-2 z-4 rounded-sm bg-black/65 px-1.75 py-0.75 text-caption font-bold tracking-wider text-white/85 uppercase displayonly:top-12",
          state.protocol === "vnc" && "border-l-2 border-accent",
          state.protocol === "spice" && "border-l-2 border-accent-2",
        )}
      >
        {state.badge}
      </div>
      <div role="toolbar" aria-label="Display controls" class="absolute top-2 left-2 z-4 flex gap-1 displayonly:top-12">
        <DisplayTool action="enterDisplayOnly" icon="maximize" title={DISPLAY_ONLY_TITLE} reason={displayReason} />
        <DisplayTool action="reconnectDisplay" icon="refresh" title={RECONNECT_TITLE} reason={displayReason} />
        <DisplayTool action="sendCad" icon="keyboard" title={CAD_TITLE} reason={cadReason} />
      </div>
      {state.loading && (
        <div
          aria-hidden="true"
          class="absolute top-1/2 left-1/2 z-3 size-7 -translate-x-1/2 -translate-y-1/2 animate-spin rounded-full border-2 border-white/18 border-t-accent"
        />
      )}
      <div
        id="displayHint"
        aria-live="polite"
        class={cn(
          "absolute inset-0 z-3 flex flex-col items-center justify-center gap-1.75 p-6 text-center text-field text-white/85",
          hint.kind === "none" && "pointer-events-none",
          hint.kind === "loading" && "pointer-events-none justify-end",
          (hint.kind === "failed" || hint.kind === "native") && "bg-black/25",
        )}
      >
        <HintContent hint={hint} />
      </div>
    </div>
  );
};

export type SerialViewProps = {
  readonly state: SerialState;
  /** A stable callback: the controller opens the terminal in this element. */
  readonly terminalRef: Ref<HTMLDivElement>;
  readonly onResized: () => void;
};

type Drag = { readonly startY: number; readonly startHeight: number };

/** Height of the terminal box: drag state on the window while a drag runs, and a refit after every change. */
const useSerialHeight = (onResized: () => void) => {
  const [height, setHeight] = useState(SERIAL_DEFAULT_HEIGHT);
  const drag = useRef<Drag | null>(null);

  useEffect(() => {
    onResized();
  }, [height, onResized]);

  useEffect(() => {
    const end = (): void => {
      if (drag.current !== null) {
        drag.current = null;
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
      }
    };
    const move = (clientY: number): void => {
      if (drag.current !== null) {
        setHeight(clampSerialHeight(drag.current.startHeight + clientY - drag.current.startY));
      }
    };
    const onMouseMove = (event: MouseEvent): void => {
      move(event.clientY);
    };
    const onTouchMove = (event: TouchEvent): void => {
      const [touch] = event.touches;
      if (touch !== undefined) {
        move(touch.clientY);
      }
    };
    globalThis.addEventListener("mousemove", onMouseMove);
    globalThis.addEventListener("mouseup", end);
    globalThis.addEventListener("touchmove", onTouchMove, { passive: true });
    globalThis.addEventListener("touchend", end);
    return () => {
      globalThis.removeEventListener("mousemove", onMouseMove);
      globalThis.removeEventListener("mouseup", end);
      globalThis.removeEventListener("touchmove", onTouchMove);
      globalThis.removeEventListener("touchend", end);
      end();
    };
  }, []);

  const begin = (clientY: number): void => {
    drag.current = { startY: clientY, startHeight: height };
    document.body.style.cursor = "ns-resize";
    document.body.style.userSelect = "none";
  };
  return { height, setHeight, begin };
};

type ResizeHandleProps = {
  readonly height: number;
  readonly setHeight: (height: number) => void;
  readonly begin: (clientY: number) => void;
};

/** The edge under the terminal: drag it, or use the arrow keys (16px, Shift 48px) and Home/End. */
const SerialResizeHandle = ({ height, setHeight, begin }: ResizeHandleProps) => (
  <div
    id="serialResize"
    role="separator"
    aria-orientation="horizontal"
    aria-label="Resize serial console"
    aria-valuemin={SERIAL_MIN_HEIGHT}
    aria-valuemax={SERIAL_MAX_HEIGHT}
    aria-valuenow={height}
    aria-valuetext={`${height} pixels`}
    tabIndex={0}
    title="Drag to resize"
    class="h-1 cursor-ns-resize bg-border hover:bg-accent focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
    onMouseDown={(event) => {
      event.preventDefault();
      begin(event.clientY);
    }}
    onTouchStart={(event) => {
      const [touch] = event.touches;
      if (event.touches.length === 1 && touch !== undefined) {
        event.preventDefault();
        begin(touch.clientY);
      }
    }}
    onKeyDown={(event) => {
      const next = serialHeightForKey(event.key, event.shiftKey, height);
      if (next !== null) {
        event.preventDefault();
        setHeight(next);
      }
    }}
  />
);

const SerialStatusLine = ({ status }: { readonly status: SerialState["status"] }) => (
  <div
    id="serialStatus"
    role="status"
    aria-live="polite"
    class={cn("px-2.5 py-1.5 text-xs empty:hidden", status === "failed" ? "text-danger-text" : "text-fg-dim")}
  >
    {status === "loading" && "Loading terminal…"}
    {status === "failed" && (
      <>
        Serial terminal failed to load.
        <Button data-action="reconnectSerial" class="ml-1.5 min-h-0 px-2 py-0.5">
          Retry
        </Button>
      </>
    )}
  </div>
);

/** `#serialpanel`: the xterm.js terminal with its status line, resize handle and buttons. */
export const SerialView = ({ state, terminalRef, onResized }: SerialViewProps) => {
  const { height, setHeight, begin } = useSerialHeight(onResized);
  return (
    <div
      id="serialpanel"
      class={cn(
        "mb-3.5 overflow-hidden rounded-md border bg-serial displayonly:hidden",
        state.connected ? "border-success/50" : "border-border",
        !state.visible && "hidden",
      )}
    >
      <SerialStatusLine status={state.status} />
      <div
        id="serialterm"
        ref={terminalRef}
        role="group"
        aria-label="Serial console terminal"
        style={{ height: `${height}px` }}
        class="xterm-host w-full overflow-hidden bg-serial px-2 py-1.5 focus-within:outline-2 focus-within:-outline-offset-2 focus-within:outline-accent"
      />
      <SerialResizeHandle height={height} setHeight={setHeight} begin={begin} />
      <div class="flex gap-1.25 border-t border-border-soft px-2.5 py-1.5">
        <Button data-action="clearSerial">
          Clear
        </Button>
        <Button data-action="exportSerial">
          Export
        </Button>
        <span class="flex-1" />
        <Button data-action="manualDisconnectSerial">
          Disconnect
        </Button>
      </div>
    </div>
  );
};

/** `#consoleHint`: why the console is empty. Nothing renders while the display should be showing. */
export const ConsoleHint = ({ vm }: { readonly vm: Vm | null }) => {
  const notice = consoleNotice(vm);
  return (
    <div id="consoleHint" role="status" aria-live="polite" class="displayonly:hidden">
      {notice !== null && (
        <div class="flex min-h-24 flex-col justify-center gap-1.25 rounded-md border border-dashed border-border bg-bg-alt p-4 text-field text-fg-muted">
          <strong>{notice.title}</strong>
          <span class="text-xs text-fg-dim">{notice.detail}</span>
        </div>
      )}
    </div>
  );
};
