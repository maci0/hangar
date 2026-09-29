import { render, type ComponentChild, type Ref } from "preact";
import { ConsoleHint, DisplayView, SerialView, type DisplayActions, type SerialActions } from "@/components/console";
import { DisplayOnlyBar } from "@/components/display-only-bar";
import { MigrationBar } from "@/components/migration-bar";
import { createDisplayController, IDLE_DISPLAY, type DisplayController, type DisplayHost, type DisplayState } from "@/lib/display";
import {
  createMigrationController,
  IDLE_MIGRATION,
  type MigrationController,
  type MigrationHost,
  type MigrationView,
} from "@/lib/migration";
import { createSerialController, IDLE_SERIAL, type SerialController, type SerialHost, type SerialState } from "@/lib/serial";
import type { VmAction } from "@/lib/actions";
import type { Vm } from "@/lib/vm";

/** What the console tab, display-only mode and the migration bar need from the app. */
export type ConsoleHost = DisplayHost & SerialHost & MigrationHost;

/** The selected VM and the reason each VM action is off (null when it works), for the display buttons. */
export type ConsoleProps = {
  readonly vm: Vm | null;
  readonly actionReason: (vmAction: VmAction) => string | null;
  /** Sends Ctrl+Alt+Del to the guest (a daemon call). */
  readonly sendCad: () => void;
};

export type ConsoleBridge = {
  /** Draws the console tab, the display-only bar and the migration bar. Call once the page is drawn. */
  readonly mountConsole: () => void;
  /** Hands over the host; the controllers exist from here on. Later calls are ignored. */
  readonly initConsole: (host: ConsoleHost) => void;
  /** Draws the console tab for the selected VM (the empty-state message and the display buttons). */
  readonly setConsole: (props: ConsoleProps) => void;
  /** Opens the display of the selected VM if it is running. */
  readonly startDisplay: () => void;
  /** Closes the display clients. */
  readonly stopDisplay: () => void;
  /** Closes the display clients and opens them again (also the Retry after a client failed to load). */
  readonly reconnectDisplay: () => void;
  /** A display client exists, so display-only mode has something to show. */
  readonly displayConnected: () => boolean;
  /** Connects the serial console of the VM at `index` (no-op when it has no serial port). */
  readonly startSerial: (index: number) => void;
  /** Closes the serial socket; `clear` also empties the terminal. */
  readonly stopSerial: (clear: boolean) => void;
  /** Closes the serial console and keeps it closed until the page reloads. */
  readonly disconnectSerial: () => void;
  readonly enterDisplayOnly: () => void;
  readonly exitDisplayOnly: () => void;
  /** Starts migrating the VM with `id` (list index `index`) to `dest`; resolves whether it started. */
  readonly startMigration: (id: string, index: number, dest: string) => Promise<boolean>;
};

const REVEAL_MS = 3500;
const DISPLAY_ONLY_CLASS = "displayonly";

type Controllers = {
  readonly host: ConsoleHost;
  readonly display: DisplayController;
  readonly serial: SerialController;
  readonly migration: MigrationController;
};

/**
 * Stable refs and callbacks: Preact calls a ref function again whenever its identity changes, and
 * a resize handler that changes would refit the terminal on every draw.
 */
type Handlers = {
  readonly displayRef: Ref<HTMLDivElement>;
  readonly terminalRef: Ref<HTMLDivElement>;
  readonly onResized: () => void;
  readonly display: DisplayActions;
  readonly serial: SerialActions;
  readonly exitDisplayOnly: () => void;
  readonly cancelMigration: () => void;
};

type Live = {
  readonly handlers: Handlers;
  props: ConsoleProps;
  displayState: DisplayState;
  serialState: SerialState;
  migrationView: MigrationView;
  revealed: boolean;
  revealTimer: ReturnType<typeof setTimeout> | null;
  controllers: Controllers | null;
  displayElement: HTMLDivElement | null;
  terminalElement: HTMLDivElement | null;
};

const mount = (selector: string, node: ComponentChild): void => {
  const root = document.querySelector(selector);
  if (root) {
    render(node, root);
  }
};

const drawConsole = (live: Live): void => {
  const { handlers, props } = live;
  mount(
    "#console-root",
    <>
      <DisplayView
        state={live.displayState}
        displayReason={props.actionReason("display")}
        cadReason={props.actionReason("cad")}
        actions={handlers.display}
        elementRef={handlers.displayRef}
      />
      <SerialView state={live.serialState} terminalRef={handlers.terminalRef} onResized={handlers.onResized} actions={handlers.serial} />
      <ConsoleHint vm={props.vm} />
    </>,
  );
};

const drawDisplayOnly = (live: Live): void => {
  mount("#displayonly-root", <DisplayOnlyBar revealed={live.revealed} onExit={live.handlers.exitDisplayOnly} />);
};

const drawMigration = (live: Live): void => {
  mount("#mig_bar_container", <MigrationBar view={live.migrationView} onCancel={live.handlers.cancelMigration} />);
};

const setRevealed = (live: Live, revealed: boolean): void => {
  live.revealed = revealed;
  drawDisplayOnly(live);
};

const clearRevealTimer = (live: Live): void => {
  if (live.revealTimer !== null) {
    clearTimeout(live.revealTimer);
    live.revealTimer = null;
  }
};

const fullscreenRefused = (): void => {
  // The browser refused fullscreen (no user gesture, or not allowed). Display-only still works windowed.
};

const enterDisplayOnly = (live: Live): void => {
  const { controllers } = live;
  if (controllers === null) {
    return;
  }
  if (!controllers.display.hasClient()) {
    controllers.host.toast("No embedded display is connected", "warn");
    return;
  }
  document.body.classList.add(DISPLAY_ONLY_CLASS);
  document.documentElement.requestFullscreen().catch(fullscreenRefused);
  controllers.host.announce("Display-only, F11 or Esc to exit");
  clearRevealTimer(live);
  setRevealed(live, true);
  live.revealTimer = setTimeout(() => {
    setRevealed(live, false);
  }, REVEAL_MS);
};

const exitDisplayOnly = (live: Live): void => {
  document.body.classList.remove(DISPLAY_ONLY_CLASS);
  clearRevealTimer(live);
  setRevealed(live, false);
  if (document.fullscreenElement) {
    void document.exitFullscreen();
  }
  live.controllers?.host.announce("Exited display-only mode");
};

const createHandlers = (current: () => Live): Handlers => ({
  displayRef: (element) => {
    current().displayElement = element;
    current().controllers?.display.attach(element);
  },
  terminalRef: (element) => {
    current().terminalElement = element;
    current().controllers?.serial.attach(element);
  },
  onResized: () => {
    current().controllers?.serial.fit();
  },
  display: {
    enterDisplayOnly: () => enterDisplayOnly(current()),
    reconnect: () => current().controllers?.display.reconnect(),
    sendCad: () => current().props.sendCad(),
  },
  serial: {
    reconnect: () => current().controllers?.serial.reconnect(),
    clear: () => current().controllers?.serial.clear(),
    exportLog: () => current().controllers?.serial.exportLog(),
    disconnect: () => current().controllers?.serial.disconnect(),
  },
  exitDisplayOnly: () => exitDisplayOnly(current()),
  cancelMigration: () => {
    void current().controllers?.migration.cancel();
  },
});

const initControllers = (live: Live, host: ConsoleHost): void => {
  const display = createDisplayController(host, (next) => {
    live.displayState = next;
    drawConsole(live);
  });
  const serial = createSerialController(host, (next) => {
    live.serialState = next;
    drawConsole(live);
  });
  const migration = createMigrationController(host, (next) => {
    live.migrationView = next;
    drawMigration(live);
  });
  live.controllers = { host, display, serial, migration };
  display.attach(live.displayElement);
  serial.attach(live.terminalElement);
};

const bridgeOf = (live: Live): ConsoleBridge => ({
  mountConsole: () => {
    drawConsole(live);
    drawDisplayOnly(live);
    drawMigration(live);
  },
  initConsole: (host) => {
    if (live.controllers === null) {
      initControllers(live, host);
    }
  },
  setConsole: (props) => {
    live.props = props;
    drawConsole(live);
  },
  startDisplay: () => {
    live.controllers?.display.start();
  },
  stopDisplay: () => {
    live.controllers?.display.stop();
  },
  reconnectDisplay: () => {
    live.controllers?.display.reconnect();
  },
  displayConnected: () => live.controllers?.display.hasClient() ?? false,
  startSerial: (index) => {
    live.controllers?.serial.start(index);
  },
  stopSerial: (clear) => {
    live.controllers?.serial.stop(clear);
  },
  disconnectSerial: () => {
    live.controllers?.serial.disconnect();
  },
  enterDisplayOnly: () => {
    enterDisplayOnly(live);
  },
  exitDisplayOnly: () => {
    exitDisplayOnly(live);
  },
  startMigration: (id, index, dest) => live.controllers?.migration.start(id, index, dest) ?? Promise.resolve(false),
});

/** Console tab, display-only bar and migration bar. Draws into `#console-root`, `#displayonly-root` and `#mig_bar_container`. */
export const createConsoleBridge = (): ConsoleBridge => {
  const live: Live = {
    handlers: createHandlers(() => live),
    props: { vm: null, actionReason: () => null, sendCad: () => undefined },
    displayState: IDLE_DISPLAY,
    serialState: IDLE_SERIAL,
    migrationView: IDLE_MIGRATION,
    revealed: false,
    revealTimer: null,
    controllers: null,
    displayElement: null,
    terminalElement: null,
  };
  return bridgeOf(live);
};
