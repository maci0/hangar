/** Globals the vendored bundles register once `ensureAsset` has loaded them. */
import type { FitAddon as XtermFit } from "@xterm/addon-fit";
import type { WebglAddon as XtermWebgl } from "@xterm/addon-webgl";
import type { Terminal as Xterm } from "@xterm/xterm";

/** The part of noVNC's RFB client the console uses. */
export type RfbClient = {
  readonly addEventListener: (type: "connect" | "disconnect" | "credentialsrequired", listener: () => void) => void;
  readonly disconnect: () => void;
  readonly sendCredentials: (credentials: { readonly password: string }) => void;
  scaleViewport: boolean;
  resizeSession: boolean;
};

export type RfbConstructor = new (target: HTMLElement, url: string, options: Readonly<Record<string, never>>) => RfbClient;

/** The bundle exposes the RFB class as `default`; `RFB` is accepted so a re-vendor cannot break the console. */
export type NoVncModule = { readonly default?: RfbConstructor; readonly RFB?: RfbConstructor };

export type SpiceOptions = {
  readonly uri: string;
  readonly password: string;
  readonly screen_id: string;
  readonly onerror: (error: unknown) => void;
  readonly onsuccess: () => void;
};

export type SpiceConnection = { readonly stop: () => void };

export type SpiceModule = { readonly SpiceMainConn: new (options: SpiceOptions) => SpiceConnection };

declare global {
  var noVNC: NoVncModule | undefined;
  var SpiceHtml5: SpiceModule | undefined;
  var Terminal: typeof Xterm | undefined;
  var FitAddon: { readonly FitAddon: typeof XtermFit } | undefined;
  var WebglAddon: { readonly WebglAddon: typeof XtermWebgl } | undefined;
}
