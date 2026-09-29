/** Migration progress: what the status poll means, and the controller that runs the poll. */

export const MIGRATION_POLL_MS = 500;
export const MIGRATION_FETCH_TIMEOUT_MS = 10_000;
/** How long a finished migration stays on screen. */
export const MIGRATION_LINGER_MS = 3000;
/** Consecutive empty polls before the connection counts as lost. */
export const MIGRATION_MAX_POLL_FAILS = 5;
const PERCENT_MAX = 100;

export type MigrationTone = "active" | "success" | "danger" | "warn";

/** The progress bar: hidden, or a label, a fill (null while the daemon reports none) and a color. */
export type MigrationView =
  | { readonly kind: "idle" }
  | { readonly kind: "active"; readonly label: string; readonly percent: number | null; readonly tone: MigrationTone };

export const IDLE_MIGRATION: MigrationView = { kind: "idle" };

export type MigrationOutcome = "completed" | "failed" | "cancelled";

/** One poll answer: still running, finished, or not readable. */
export type MigrationPoll =
  | { readonly kind: "running"; readonly status: string; readonly percent: number | null }
  | { readonly kind: "finished"; readonly outcome: MigrationOutcome }
  | { readonly kind: "unreadable" };

const OUTCOMES: Readonly<Record<string, MigrationOutcome>> = {
  completed: "completed",
  failed: "failed",
  error: "failed",
  cancelled: "cancelled",
};

/** Reads the parsed body of `GET /api/vms/<n>/migrate`; a percentage is clamped to 0-100. */
export const parseMigrationPoll = (body: unknown): MigrationPoll => {
  if (typeof body !== "object" || body === null || !("status" in body) || typeof body.status !== "string") {
    return { kind: "unreadable" };
  }
  const { status } = body;
  const outcome = OUTCOMES[status];
  if (outcome !== undefined) {
    return { kind: "finished", outcome };
  }
  const percent = "pct" in body && typeof body.pct === "number" ? Math.min(PERCENT_MAX, Math.max(0, body.pct)) : null;
  return { kind: "running", status, percent };
};

type Finish = { readonly label: string; readonly tone: MigrationTone; readonly announcement: string };

const FINISHES: Readonly<Record<MigrationOutcome, Finish>> = {
  completed: { label: "Migration completed.", tone: "success", announcement: "Migration completed" },
  failed: { label: "Migration failed.", tone: "danger", announcement: "Migration failed" },
  cancelled: { label: "Migration cancelled.", tone: "warn", announcement: "Migration cancelled" },
};

export const finishOf = (outcome: MigrationOutcome): Finish => FINISHES[outcome];

/** What the app provides: the daemon calls, VM lookup by stable id, and the status line and toasts. */
export type MigrationHost = {
  /** POSTs a form body; resolves the response, or null after reporting a failure itself. */
  readonly post: (path: string, body: string) => Promise<Response | null>;
  /** Index of the VM with this id in the current list, or -1. */
  readonly indexOfId: (id: string) => number;
  readonly announce: (text: string) => void;
  readonly toast: (message: string, type: "warn" | "error") => void;
};

export type MigrationController = {
  /** Starts a migration of the VM with `id` (at list index `index`) to `dest`; resolves whether it started. */
  readonly start: (id: string, index: number, dest: string) => Promise<boolean>;
  /** Asks the daemon to cancel the running migration. */
  readonly cancel: () => Promise<void>;
};

type Timer = ReturnType<typeof setTimeout>;

type Migration = {
  readonly host: MigrationHost;
  readonly publish: (view: MigrationView) => void;
  migrating: boolean;
  id: string | null;
  pollTimer: Timer | null;
  hideTimer: Timer | null;
  failures: number;
  /** Last fill the daemon reported; failed and cancelled keep it. */
  percent: number | null;
  /** Polls once; the poll timer calls it. */
  readonly tick: () => void;
};

const clearTimers = (migration: Migration): void => {
  if (migration.pollTimer !== null) {
    clearTimeout(migration.pollTimer);
    migration.pollTimer = null;
  }
  if (migration.hideTimer !== null) {
    clearTimeout(migration.hideTimer);
    migration.hideTimer = null;
  }
};

const hide = (migration: Migration): void => {
  migration.migrating = false;
  migration.id = null;
  migration.failures = 0;
  clearTimers(migration);
  migration.publish(IDLE_MIGRATION);
};

const showRunning = (migration: Migration, label: string, percent: number | null): void => {
  migration.percent = percent;
  migration.publish({ kind: "active", label, percent, tone: "active" });
};

const finish = (migration: Migration, outcome: MigrationOutcome): void => {
  const { label, tone, announcement } = finishOf(outcome);
  migration.publish({ kind: "active", label, percent: outcome === "completed" ? PERCENT_MAX : migration.percent, tone });
  migration.host.announce(announcement);
  migration.hideTimer = setTimeout(() => {
    hide(migration);
  }, MIGRATION_LINGER_MS);
};

/** The parsed status body; `null` when the request failed or timed out, `undefined` when the body is not JSON. */
const fetchStatus = async (index: number): Promise<unknown> => {
  const response = await fetch(`/api/vms/${index}/migrate`, { signal: AbortSignal.timeout(MIGRATION_FETCH_TIMEOUT_MS) }).catch(() => null);
  if (response === null) {
    return null;
  }
  return response.json().catch((): undefined => undefined);
};

const schedulePoll = (migration: Migration): void => {
  migration.pollTimer = setTimeout(migration.tick, MIGRATION_POLL_MS);
};

/**
 * A single dropped poll (timeout, busy daemon during transfer) must not abort a migration that is
 * still running server-side, so a few consecutive failures are tolerated.
 */
const onPollFailure = (migration: Migration): void => {
  migration.failures += 1;
  if (migration.failures >= MIGRATION_MAX_POLL_FAILS) {
    hide(migration);
    migration.host.announce("Migration failed");
    return;
  }
  showRunning(migration, "Migration in progress... (retrying)", migration.percent);
  schedulePoll(migration);
};

const onPollAnswer = (migration: Migration, answer: MigrationPoll): void => {
  if (answer.kind === "finished") {
    finish(migration, answer.outcome);
    return;
  }
  if (answer.kind === "running") {
    showRunning(migration, `Migration ${answer.status}...`, answer.percent ?? migration.percent);
  } else {
    showRunning(migration, "Migration polling error", migration.percent);
  }
  schedulePoll(migration);
};

const poll = async (migration: Migration): Promise<void> => {
  if (migration.id === null) {
    hide(migration);
    return;
  }
  const index = migration.host.indexOfId(migration.id);
  if (index < 0) {
    migration.host.toast("Migrating VM no longer in the list", "warn");
    hide(migration);
    return;
  }
  const body = await fetchStatus(index);
  if (body === null) {
    onPollFailure(migration);
    return;
  }
  migration.failures = 0;
  onPollAnswer(migration, parseMigrationPoll(body));
};

const startedOk = async (response: Response): Promise<boolean> => {
  const body: unknown = await response.json().catch((): undefined => undefined);
  return typeof body === "object" && body !== null && "status" in body && body.status === "started";
};

const startMigration = async (migration: Migration, id: string, index: number, dest: string): Promise<boolean> => {
  if (migration.migrating) {
    return false;
  }
  migration.migrating = true;
  migration.id = id;
  const response = await migration.host.post(`/api/vms/${index}/migrate`, `dest=${encodeURIComponent(dest)}`);
  if (response === null || !(await startedOk(response))) {
    if (response !== null) {
      migration.host.toast("Migration failed to start", "error");
    }
    migration.migrating = false;
    migration.id = null;
    return false;
  }
  clearTimers(migration);
  migration.failures = 0;
  showRunning(migration, "Migration in progress...", null);
  void poll(migration);
  return true;
};

const cancelMigration = async (migration: Migration): Promise<void> => {
  if (migration.id === null) {
    return;
  }
  const index = migration.host.indexOfId(migration.id);
  if (index < 0) {
    hide(migration);
    return;
  }
  const response = await migration.host.post(`/api/vms/${index}/migrate/cancel`, "");
  if (response !== null) {
    showRunning(migration, "Cancelling...", migration.percent);
    migration.host.announce("Migration cancel requested");
  }
};

export const createMigrationController = (host: MigrationHost, publish: (view: MigrationView) => void): MigrationController => {
  const migration: Migration = {
    host,
    publish,
    migrating: false,
    id: null,
    pollTimer: null,
    hideTimer: null,
    failures: 0,
    percent: null,
    tick: () => {
      void poll(migration);
    },
  };
  return {
    start: (id, index, dest) => startMigration(migration, id, index, dest),
    cancel: () => cancelMigration(migration),
  };
};
