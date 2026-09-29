/**
 * On-demand vendored bundles. The layout engine, the two console clients and the serial terminal add
 * up to over a megabyte the VM library never touches, so each is fetched the first time the surface
 * that needs it opens. Concurrent callers share the pending promise; a failed or timed-out load
 * clears it so the surface's Retry starts a fresh attempt.
 */
export const ASSET_LOAD_TIMEOUT_MS = 15_000;

const pendingAssets = new Map<string, Promise<void>>();

const once = { once: true } as const;

/** Loads a script once; resolves at once when `isReady` already reports the bundle's global. */
export const ensureAsset = (src: string, isReady: () => boolean): Promise<void> => {
  if (isReady()) {
    return Promise.resolve();
  }
  const pending = pendingAssets.get(src);
  if (pending !== undefined) {
    return pending;
  }
  const { promise, resolve, reject } = Promise.withResolvers<undefined>();
  pendingAssets.set(src, promise);
  const script = document.createElement("script");
  let settled = false;
  const settle = (ok: boolean): void => {
    if (settled) {
      return;
    }
    settled = true;
    if (ok) {
      resolve(undefined);
      return;
    }
    script.remove();
    pendingAssets.delete(src);
    reject(new Error(`Failed to load ${src}`));
  };
  script.addEventListener("load", () => {
    settle(isReady());
  }, once);
  script.addEventListener("error", () => {
    settle(false);
  }, once);
  AbortSignal.timeout(ASSET_LOAD_TIMEOUT_MS).addEventListener("abort", () => {
    settle(false);
  }, once);
  script.src = src;
  script.async = true;
  document.head.append(script);
  return promise;
};

/** Loads a stylesheet once. */
export const ensureStylesheet = (href: string): Promise<void> => {
  if (document.querySelector(`link[data-asset="${href}"]`) !== null) {
    return Promise.resolve();
  }
  const { promise, resolve, reject } = Promise.withResolvers<undefined>();
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  link.dataset.asset = href;
  link.addEventListener("load", () => {
    resolve(undefined);
  }, once);
  link.addEventListener("error", () => {
    link.remove();
    reject(new Error(`Failed to load ${href}`));
  }, once);
  document.head.append(link);
  return promise;
};
