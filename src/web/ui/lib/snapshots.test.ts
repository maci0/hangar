import { describe, expect, test } from "bun:test";
import { parseSnapshotList, relAge } from "@/lib/snapshots";

const NOW = Date.parse("2026-01-10T12:00:00");

describe("relAge", () => {
  test("names the largest unit", () => {
    expect(relAge("2026-01-10 11:59:30", NOW)).toBe("just now");
    expect(relAge("2026-01-10 11:15:00", NOW)).toBe("45 min ago");
    expect(relAge("2026-01-10 07:00:00", NOW)).toBe("5 h ago");
    expect(relAge("2026-01-07 12:00:00", NOW)).toBe("3 d ago");
  });

  test("empty for a stamp that does not parse or lies ahead", () => {
    expect(relAge("soon", NOW)).toBe("");
    expect(relAge("2026-01-11 12:00:00", NOW)).toBe("");
  });
});

describe("parseSnapshotList", () => {
  test("reads tag and time per line", () => {
    const items = parseSnapshotList("base\t2026-01-10 11:00:00\n\nwith-tools\t\n", NOW);
    expect(items).toEqual([
      { tag: "base", when: "2026-01-10 11:00:00", age: "1 h ago" },
      { tag: "with-tools", when: "", age: "" },
    ]);
  });

  test("none and empty bodies give an empty list", () => {
    expect(parseSnapshotList("(none)\n", NOW)).toEqual([]);
    expect(parseSnapshotList("", NOW)).toEqual([]);
  });
});
