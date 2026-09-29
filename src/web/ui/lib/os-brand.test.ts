import { describe, expect, test } from "bun:test";
import { osBrand } from "@/lib/os-brand";

describe("osBrand", () => {
  test("recognises a distro from the name or the OS label", () => {
    expect(osBrand("ubuntu-24", "Linux")).toEqual({ color: "#E95420", text: "U" });
    expect(osBrand("box", "Microsoft Windows")).toEqual({ color: "#0078D4", text: "W" });
  });

  test("the more specific match wins", () => {
    expect(osBrand("openbsd-7", "Other").text).toBe("O");
    expect(osBrand("freebsd", "Other").text).toBe("B");
    expect(osBrand("rocky-9", "Linux").text).toBe("R");
  });

  test("an unknown OS takes the accent and the first letter", () => {
    expect(osBrand("plan9", "Other")).toEqual({ color: "var(--accent)", text: "P" });
    expect(osBrand("", "")).toEqual({ color: "var(--accent)", text: "?" });
  });
});
