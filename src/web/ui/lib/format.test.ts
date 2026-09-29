import { describe, expect, test } from "bun:test";
import { fmtBytes, memGiB, memText, percentOf, statusLabel, visibleTags } from "@/lib/format";

describe("memory labels", () => {
  test("stay in exact MiB below one GiB", () => {
    expect(memText(0)).toBe("0 MiB");
    expect(memText(512)).toBe("512 MiB");
    expect(memText(1023)).toBe("1023 MiB");
  });

  test("scale to GiB from 1024 with one decimal", () => {
    expect(memText(1024)).toBe("1 GiB");
    expect(memText(1536)).toBe("1.5 GiB");
    expect(memText(4096)).toBe("4 GiB");
    expect(memGiB(1000)).toBe(1);
  });

  test("treat a missing quantity as zero", () => {
    expect(memText(Number.NaN)).toBe("0 MiB");
    expect(memGiB(Number.NaN)).toBe(0);
  });
});

describe("fmtBytes", () => {
  test("uses binary units", () => {
    expect(fmtBytes(0)).toBe("0 B");
    expect(fmtBytes(1023)).toBe("1023 B");
    expect(fmtBytes(1024)).toBe("1.0 KiB");
    expect(fmtBytes(1536 * 1024 * 1024)).toBe("1.5 GiB");
  });

  test("stops at TiB", () => {
    expect(fmtBytes(2048 * 1024 ** 4)).toBe("2048.0 TiB");
  });

  test("rejects negative and non-finite sizes", () => {
    expect(fmtBytes(-1)).toBe("?");
    expect(fmtBytes(Number.NaN)).toBe("?");
    expect(fmtBytes(Number.POSITIVE_INFINITY)).toBe("?");
  });
});

describe("statusLabel", () => {
  test("names the four states and passes others through", () => {
    expect(statusLabel("running")).toBe("Running");
    expect(statusLabel("stopped")).toBe("Stopped");
    expect(statusLabel("weird")).toBe("weird");
    expect(statusLabel("")).toBe("Unknown");
  });
});

describe("visibleTags", () => {
  test("drops empty entries and the folder tag", () => {
    expect(visibleTags("prod, web,, folder:Lab/One ,Folder:x")).toEqual(["prod", "web"]);
    expect(visibleTags("")).toEqual([]);
  });
});

describe("percentOf", () => {
  test("rounds, caps at 100 and guards a zero whole", () => {
    expect(percentOf(1, 3)).toBe(33);
    expect(percentOf(5, 2)).toBe(100);
    expect(percentOf(5, 0)).toBe(0);
  });
});
