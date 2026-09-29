import { describe, expect, test } from "bun:test";
import { isLight, isTheme, nextTheme, themeLabel } from "@/lib/theme";

describe("theme", () => {
  test("cycles system, light, dark and wraps", () => {
    expect(nextTheme("system")).toBe("light");
    expect(nextTheme("light")).toBe("dark");
    expect(nextTheme("dark")).toBe("system");
  });

  test("only system follows the OS preference", () => {
    expect(isLight("system", true)).toBe(true);
    expect(isLight("system", false)).toBe(false);
    expect(isLight("light", false)).toBe(true);
    expect(isLight("dark", true)).toBe(false);
  });

  test("accepts only the three theme names", () => {
    expect(isTheme("light")).toBe(true);
    expect(isTheme("Light")).toBe(false);
    expect(isTheme(null)).toBe(false);
  });

  test("label names the active theme", () => {
    expect(themeLabel("dark")).toBe("Theme: Dark (click to change)");
  });
});
