import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  createMigrationController,
  finishOf,
  parseMigrationPoll,
  type MigrationController,
  type MigrationHost,
  type MigrationView,
} from "@/lib/migration";

describe("parseMigrationPoll", () => {
  test("reads a running status with its percentage", () => {
    expect(parseMigrationPoll({ status: "active", pct: 42.5 })).toEqual({ kind: "running", status: "active", percent: 42.5 });
  });

  test("clamps the percentage to 0-100", () => {
    expect(parseMigrationPoll({ status: "active", pct: 140 })).toEqual({ kind: "running", status: "active", percent: 100 });
    expect(parseMigrationPoll({ status: "active", pct: -3 })).toEqual({ kind: "running", status: "active", percent: 0 });
  });

  test("has no percentage when the daemon sends none", () => {
    expect(parseMigrationPoll({ status: "setup" })).toEqual({ kind: "running", status: "setup", percent: null });
    expect(parseMigrationPoll({ status: "setup", pct: "12" })).toEqual({ kind: "running", status: "setup", percent: null });
  });

  test("maps the terminal statuses", () => {
    expect(parseMigrationPoll({ status: "completed" })).toEqual({ kind: "finished", outcome: "completed" });
    expect(parseMigrationPoll({ status: "failed" })).toEqual({ kind: "finished", outcome: "failed" });
    expect(parseMigrationPoll({ status: "error" })).toEqual({ kind: "finished", outcome: "failed" });
    expect(parseMigrationPoll({ status: "cancelled" })).toEqual({ kind: "finished", outcome: "cancelled" });
  });

  test("rejects malformed bodies", () => {
    expect(parseMigrationPoll(undefined)).toEqual({ kind: "unreadable" });
    expect(parseMigrationPoll(null)).toEqual({ kind: "unreadable" });
    expect(parseMigrationPoll([])).toEqual({ kind: "unreadable" });
    expect(parseMigrationPoll("active")).toEqual({ kind: "unreadable" });
    expect(parseMigrationPoll({ status: 7 })).toEqual({ kind: "unreadable" });
    expect(parseMigrationPoll({})).toEqual({ kind: "unreadable" });
  });
});

describe("finishOf", () => {
  test("colors each outcome", () => {
    expect(finishOf("completed").tone).toBe("success");
    expect(finishOf("failed").tone).toBe("danger");
    expect(finishOf("cancelled").tone).toBe("warn");
  });
});

type Recorder = {
  readonly controller: MigrationController;
  readonly views: Array<MigrationView>;
  readonly announced: Array<string>;
  readonly toasts: Array<string>;
  readonly posts: Array<string>;
};

const json = (body: unknown): Response => Response.json(body);

/** A controller over a fake daemon: `answers` maps a POST path to its response. */
const recorder = (answers: Readonly<Record<string, Response>>): Recorder => {
  const views: Array<MigrationView> = [];
  const announced: Array<string> = [];
  const toasts: Array<string> = [];
  const posts: Array<string> = [];
  const host: MigrationHost = {
    post: (path, body) => {
      posts.push(`${path} ${body}`);
      return Promise.resolve(answers[path] ?? null);
    },
    indexOfId: (id) => (id === "gone" ? -1 : 4),
    announce: (text) => {
      announced.push(text);
    },
    toast: (message) => {
      toasts.push(message);
    },
  };
  const controller = createMigrationController(host, (view) => {
    views.push(view);
  });
  return { controller, views, announced, toasts, posts };
};

const started = (): Record<string, Response> => ({ "/api/vms/4/migrate": json({ status: "started" }) });
const realFetch = globalThis.fetch;
const fetched: Array<string> = [];
let statuses: Array<string> = [];

beforeEach(() => {
  statuses = [];
  fetched.length = 0;
  globalThis.fetch = ((input: string) => {
    fetched.push(input);
    const next = statuses.shift();
    return next === undefined ? Promise.reject(new Error("offline")) : Promise.resolve(new Response(next));
  }) as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("migration controller", () => {
  test("does not poll when the daemon refuses to start", async () => {
    const rec = recorder({ "/api/vms/4/migrate": json({ status: "busy" }) });
    expect(await rec.controller.start("a", 4, "tcp:10.0.0.2:4444")).toBe(false);
    expect(rec.posts).toEqual(["/api/vms/4/migrate dest=tcp%3A10.0.0.2%3A4444"]);
    expect(rec.toasts).toEqual(["Migration failed to start"]);
    expect(rec.views).toEqual([]);
    expect(fetched).toEqual([]);
  });

  test("stays quiet when the request itself failed", async () => {
    const rec = recorder({});
    expect(await rec.controller.start("a", 4, "tcp:h:1")).toBe(false);
    expect(rec.toasts).toEqual([]);
  });

  test("shows progress, then the finished state", async () => {
    statuses = ['{"status":"completed"}'];
    const rec = recorder(started());
    expect(await rec.controller.start("a", 4, "tcp:h:1")).toBe(true);
    await Bun.sleep(20);
    expect(rec.views[0]).toEqual({ kind: "active", label: "Migration in progress...", percent: null, tone: "active" });
    expect(rec.views.at(-1)).toEqual({ kind: "active", label: "Migration completed.", percent: 100, tone: "success" });
    expect(rec.announced).toEqual(["Migration completed"]);
    expect(fetched).toEqual(["/api/vms/4/migrate"]);
  });

  test("a second start is refused while one runs", async () => {
    statuses = ['{"status":"completed"}'];
    const rec = recorder(started());
    expect(await rec.controller.start("a", 4, "tcp:h:1")).toBe(true);
    expect(await rec.controller.start("a", 4, "tcp:h:1")).toBe(false);
  });

  test("keeps polling after one empty answer", async () => {
    const rec = recorder(started());
    await rec.controller.start("a", 4, "tcp:h:1");
    await Bun.sleep(20);
    expect(rec.views.at(-1)).toEqual({ kind: "active", label: "Migration in progress... (retrying)", percent: null, tone: "active" });
    expect(rec.announced).toEqual([]);
  });

  test("warns when the migrating VM leaves the list", async () => {
    const rec = recorder(started());
    await rec.controller.start("gone", 4, "tcp:h:1");
    await Bun.sleep(20);
    expect(rec.toasts).toEqual(["Migrating VM no longer in the list"]);
    expect(rec.views.at(-1)).toEqual({ kind: "idle" });
  });

  test("cancel asks the daemon and says so", async () => {
    statuses = ['{"status":"active","pct":30}'];
    const rec = recorder({ ...started(), "/api/vms/4/migrate/cancel": json({}) });
    await rec.controller.start("a", 4, "tcp:h:1");
    await Bun.sleep(20);
    await rec.controller.cancel();
    expect(rec.posts.at(-1)).toBe("/api/vms/4/migrate/cancel ");
    expect(rec.views.at(-1)).toEqual({ kind: "active", label: "Cancelling...", percent: 30, tone: "active" });
    expect(rec.announced).toEqual(["Migration cancel requested"]);
  });
});
