import { describe, expect, test } from "bun:test";
import { parseCatalog } from "@/lib/catalog";

describe("parseCatalog", () => {
  test("turns a template into a card with the OS emblem", () => {
    const [card] = parseCatalog([{ id: "ubuntu-24", name: "Ubuntu 24.04", guest_os: 0, description: "LTS", cpu_cores: 2, memory_mb: 2048, disk_size_gb: 20 }]);
    expect(card).toMatchObject({ id: "ubuntu-24", os: "Linux", memory: "2 GiB", diskGb: 20, monogram: "U", brandColor: "#E95420" });
  });

  test("skips entries without an id or name and reads a non-list as empty", () => {
    expect(parseCatalog([{ name: "x" }, null, 3])).toEqual([]);
    expect(parseCatalog({})).toEqual([]);
  });
});
